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

Six tests fail. Two are bookkeeping (the demo output and the "2 syncs" count in "update
then read"). "recover on a fresh store whose first update was cut short" fails for the
same reason as the first one below (`.drop`, `crash_after = 2`: it expects the new
version and finds a blank page). The other three are the real damage:

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
- "seeded oracle over three pages" fails with the same `error.Unrecoverable`, reached by
  its own random sequence of updates and power cuts.

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
slot area:  [image of X] [image of Y] [commit page: checksum of image X, checksum of image Y]

update2(X, Y):
  1. write both images and the commit page to the slot area, sync   <- the commit point
  2. write both home pages, sync

recover():
  commit page ok, both slot images ok, and each image's
  stored checksum equals the one in the commit page     -> copy both images home, sync (redo)
  otherwise                                             -> do nothing
```

The commit page is one page, so after a crash it is either complete or not (its own
checksum says which). Until it is durable no home page has been written, so the state is
(old, old). Once it is durable, recovery can always finish the job, so the state becomes
(new, new). Recovery must run after every crash, before the next `update2`.

The last condition of `recover` is the part that is easy to leave out, and without it the
protocol is not atomic. After a completed `update2(A, a)` the slot area holds the intact
images A and a and a valid commit page. Now `update2(B, b)` writes image B, the power
fails, and the OS happened to have flushed that one write (fate 2, "kept"). The slot
area holds B, a and the old commit page: three pages that each pass their own checksum.
A recovery that only asks "is the commit page ok, are both images ok?" copies (B, a)
home. That is the mixed state again, this time produced by the recovery code. A torn
image is not the danger here, its own checksum rejects it. The danger is an image that
is *intact and from another update*, which is the lost write of exercise 4, and the cure
is the same: the expected checksum must live outside the page it describes. (A sequence
number stored in all three pages would also do.)

```zig
// Slot area: pages 0 and 1 hold the images of X and Y, page 2 the commit
// page. Homes: pages 3 and 4.
const slot_x = 0;
const slot_y = 1;
const commit_no = 2;
const home_x = 3;
const home_y = 4;

fn update2(s: Storage, x: *Page, y: *Page) Storage.Error!void {
    page_mod.seal(x, slot_x);
    page_mod.seal(y, slot_y);
    var commit: Page = @splat(0);
    @memcpy(commit[0..6], "commit");
    // Bind the commit page to exactly these two images.
    std.mem.writeInt(u32, commit[8..12], page_mod.storedChecksum(x), .little);
    std.mem.writeInt(u32, commit[12..16], page_mod.storedChecksum(y), .little);
    page_mod.seal(&commit, commit_no);
    try s.writePage(slot_x, x);
    try s.writePage(slot_y, y);
    try s.writePage(commit_no, &commit);
    try s.sync(); // the commit point: no home page is touched before this
    page_mod.seal(x, home_x);
    page_mod.seal(y, home_y);
    try s.writePage(home_x, x);
    try s.writePage(home_y, y);
    try s.sync();
}

fn recover2(s: Storage) Storage.Error!void {
    var commit: Page = undefined;
    var x: Page = undefined;
    var y: Page = undefined;
    if (try page_mod.readChecked(s, commit_no, &commit) != .ok) return;
    if (try page_mod.readChecked(s, slot_x, &x) != .ok) return;
    if (try page_mod.readChecked(s, slot_y, &y) != .ok) return;
    // An image can be intact and still belong to an earlier update.
    if (page_mod.storedChecksum(&x) != std.mem.readInt(u32, commit[8..12], .little)) return;
    if (page_mod.storedChecksum(&y) != std.mem.readInt(u32, commit[12..16], .little)) return;
    page_mod.seal(&x, home_x);
    page_mod.seal(&y, home_y);
    try s.writePage(home_x, &x);
    try s.writePage(home_y, &y);
    try s.sync();
}

test "update2: crash at every write, every mode: both old or both new" {
    for ([_]CrashMode{ .drop, .keep, .tear, .random }) |mode| {
        for (0..6) |crash_after| { // update2 issues 5 writes: stop after 0..5
            for (0..300) |seed| {
                var disk: SimDisk = .init(testing.allocator, seed);
                defer disk.deinit();
                const s = disk.storage();
                var x: Page = @splat('A');
                var y: Page = @splat('a');
                try update2(s, &x, &y); // (A, a) is durable
                disk.powerOffAfterWrites(crash_after);
                x = @splat('B');
                y = @splat('b');
                try testing.expectError(error.PowerLoss, update2(s, &x, &y));
                _ = disk.crash(mode);
                try recover2(s);

                try testing.expectEqual(page_mod.Check.ok, try page_mod.readChecked(s, home_x, &x));
                try testing.expectEqual(page_mod.Check.ok, try page_mod.readChecked(s, home_y, &y));
                const old = x[0] == 'A' and y[0] == 'a';
                const new = x[0] == 'B' and y[0] == 'b';
                try testing.expect(old or new);
                // 4 accepted writes mean the first sync passed: the update must win.
                if (crash_after >= 4) try testing.expect(new);
            }
        }
    }
}
```

Paste this below the tests of `doublewrite.zig` and it runs as it stands: 7200 simulated
power cuts on the chapter's `SimDisk`, every crash point in each of the four crash modes,
and every one ends in (A, a) or (B, b). Delete the two lines under "An image can be
intact" and the same test fails: counting instead of asserting gives 300 mixed pairs out
of 1800 runs in `.keep` mode (every run that stops after one write, the scenario above)
and 217 of 1800 in `.random`. `.drop` and `.tear` give none, because nothing new arrives
intact. A second test, not printed here, was run on the same code: 300 seeds of 50
consecutive updates each, with a power cut after a random number of writes in a random
mode and with recovery itself interrupted up to three times, checking the pair of home
pages against an oracle after every step. It passes with the binding.

Two caveats. A 32-bit checksum is a weak binding: a stale image whose checksum happens to
collide (one chance in 2^32) would be accepted, so a real log uses a wider checksum or a
sequence number. And `recover2` rewrites both home pages on every restart, even when they
are already current; that is harmless, only wasteful.

That is a write-ahead log with full-page images, a commit record and redo, limited to
one transaction at a time. Chapter 22 removes the limit: the slot area becomes an
append-only log, and each record is bound to the one before it for the same reason the
commit page here is bound to its images (Turso seeds every frame's checksum with the
previous frame's, see "Whole-page log frames" in the README). The "which version"
question is answered by LSNs, and the point at which old log can be discarded is a
checkpoint.
