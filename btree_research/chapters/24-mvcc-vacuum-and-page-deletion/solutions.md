# Chapter 24: solutions

Where a solution reports what the code does, the change was made in a scratch copy of
`zig/` and `zig build test` / `zig build run` were run on it. Anything not run is
marked as an expectation.

## 1. Visibility by hand

The rule: a snapshot `s` sees a version iff `xmin <= s` and (`xmax == 0` or `xmax > s`).

Snapshot 4:

| version | xmin <= 4 | xmax unset or > 4 | seen |
| --- | --- | --- | --- |
| `10:1-` | yes | unset | yes |
| `20:2-4` | yes | 4 > 4 is false | no |
| `20:4-` | yes (4 <= 4) | unset | yes |
| `30:3-5` | yes | 5 > 4 | yes |

So snapshot 4 sees rows 10, 20 (the new version) and 30. This agrees with the
program: in section 1 of `expected_output.txt` snapshot A = 3 reads the old version
of 20 and row 30, and snapshot B = 5 reads the new version of 20 and no row 30;
snapshot 4 lies between the two and gets the new 20 while still seeing 30. (The
boundary cases `xmin == s` and `xmax == s` are the unit test "visibility is two
comparisons" in `store.zig` / `store.rs`.)

With snapshots 3 and 5 open the horizon is 3, the smaller one. A version is dead to
everyone iff `xmax != 0 and xmax <= 3`. The two ended versions have `xmax` 4 and 5,
so none is dead to everyone. This is why the first scan in section 2 prints
`hints set 0`, and the scan after A is closed (horizon 5) prints `hints set 2`.

## 2. Stamping with `now` instead of a new tick

Change in `index.zig`:

```zig
leaf.state = .{ .deleted = store.now };   // was: store.tick()
```

Result of `zig build test` (measured): 5 of the 27 tests fail. Three fail for
bookkeeping reasons: two compare text in which the numbers moved (the dump test of
page deletion and the comparison with `expected_output.txt`), and the model test
fails in `validate`, which insists that stamps in the deleted queue are strictly
ascending (two pages unlinked by one VACUUM now share a stamp). The two that matter:

- "a scan about to step onto a page that is then deleted moves right safely" fails at
  `expectEqual(0, report.pages_recycled)`: `expected 0, found 2`.
- "recycling a deleted page too early breaks the same scan" fails at
  `expectEqual(0, db.index.recycle(db.store.horizon()))`: `expected 0, found 1`.

Why: the paused scan's snapshot is 18, and with no tick the page is stamped 18 too.
`recycle` frees while `stamp <= horizon`, and 18 <= 18. The stamp no longer separates
"snapshot taken before the unlink" from "taken after it", so the rule lets the page
go while the scan still holds its handle.

Making it safe again: free only when the stamp is strictly below the horizon.

```zig
if (leaf.state.deleted >= horizon) break;  // was: > horizon
```

Result (measured): the two recycling assertions above pass again (the scan test now
gets past them and stops later, at `expect(s < stamp)`, which is no longer true). But
7 tests fail in total, and the new failures show what was lost:

- "vacuum removes exactly what the oldest snapshot cannot see" fails at
  `expectEqual(report.pages_unlinked, report.pages_recycled)`: `expected 3, found 0`.
- "a deletion interrupted after phase 1 ..." fails at
  `expectEqual(2, report.pages_recycled)`: `expected 2, found 0`.
- "the leftmost leaf can be deleted ..." fails where it expects the old head page
  to be free already.

With no snapshot open the horizon equals `now`, which equals the stamp, so a VACUUM
can no longer recycle the pages it has just unlinked. They wait until some later
transaction advances the counter, and a snapshot taken after the unlink but before
that transaction blocks them although it cannot reach them. Taking a fresh tick for
the stamp costs one number and removes both problems. PostgreSQL's choice is the same
in spirit: `safexid` is the *next* transaction id (`nbtpage.c:2671`).

## 3. Clearing the right link of a deleted page

Change in `unlinkHalfDead`, after the stamp:

```zig
leaf.next = .nil;
```

Prediction: the paused scan follows its saved link to `#1`, sees a page that is not
live, takes its right link, which is now nil, and concludes that the chain has ended.

Result of `zig build run` (measured), section 5:

```
the scan resumes: | moved right past 1 deleted page
```

No rows after 10 and 20: rows 90, 100, 110 and 120 are lost without any error. In the
test suite the test "a scan about to step onto a page ..." stops with
`panic: attempt to use null value` where it expects row 90.

The link is not kept for the tree's sake (nothing in the tree uses it) but only for
readers that are already on their way to the page.

## 4. Empty leaves that stay

Counting leaves in the chain at the end of the first model run (measured by adding a
loop over `first_leaf ... next` to `modelRun` in a scratch copy): **239 leaves, 35 of
them empty**, for 278 rows. For comparison, 278 rows need at least 93 leaves of
capacity 3.

VACUUM ran after the last operation of that run (the run has 20000 steps and vacuums
when `step % 250 == 249`), and `vacuum` calls `markHalfDead` on every leaf it finds
empty. So each of the 35 was refused by `markHalfDead`, and since they are empty live
leaves that are not the root, the only refusal left in the code is the rightmost-child
rule: each is the last child of its parent. Deleting it would give its key range to a
leaf under a different parent, which means changing a separator one or more levels
up. PostgreSQL has the same restriction except when the page is its parent's only
child (README:240-245); then the parent goes too. Our model does not implement that
case, so here an internal page with one empty child also stays for ever. With order
4 parents are small, so "last child of its parent" is a large fraction of all leaves;
with realistic fan-out it is a small one. That last sentence is an expectation from
the arithmetic (one rightmost child per parent), not something this chapter measured
at large fan-out; the M = 16 run of section 7 is too small to show it (54 leaves, 0
empty, measured the same way).

## 5. Versions outside the tree (design sketch, not implemented)

Nothing below was built or measured for this chapter; it is a design to compare with
the code you have, following what `research/turso.md` section 15 describes.

Structures:

- `tree`: the plain B+tree of chapter 07, `key -> value`. It holds one value per key:
  the state as of the last checkpoint. No `xmin`, no `xmax`, no hints.
- `versions`: a sorted map `key -> list of (begin, end, value-or-tombstone)`, newest
  first. `begin` and `end` play the role of `xmin` and `xmax`.

Operations:

- `put(key, value)`: take a transaction id `x`; set `end = x` on the newest version in
  the list, if any; push `(begin = x, end = 0, value)`. The tree is not touched.
- `delete(key)`: the row may exist only in the tree, so there may be no version to
  end. Push a **tombstone** `(begin = x, end = 0, deleted)`. This is the answer to
  "what does delete write": a new version, not a number in an old one.
- `get(snapshot, key)`: look in `versions[key]` for the newest version visible to the
  snapshot. If there is one, it decides (a tombstone means "no row"). If there is
  none, fall through to the tree. This is only correct if every version that the tree
  already contains is older than every open snapshot; see the checkpoint rule.
- cursor: keep one position in `versions` and one in `tree`; return the smaller key;
  on equal keys take the in-memory side and advance both. Skip keys whose visible
  version is a tombstone.

Checkpoint: for each key, find the newest version with `begin <= horizon`. Write it
into the tree with an ordinary `put`, or `delete` the key if it is a tombstone. Then
the tree holds exactly what the oldest snapshot would read from the in-memory map for
that key, and every version that is not newer than the one just written can be
dropped: no open or future snapshot can need it, because the tree now answers for
them. Versions with `begin > horizon` must stay in memory, and so must the version
they shadow if a snapshot older than their `begin` is open; choosing the newest
version at or below the *horizon* (not below `now`) is what makes that automatic.

What you would expect to differ from this chapter's design (expectations, not
measurements): the tree never contains garbage, so it needs no hint bits, no
bottom-up pass and no VACUUM of entries, and it can use the textbook delete with
merging of chapter 05 as long as only the checkpoint writes to it and readers do not
run during a checkpoint. In exchange every read pays for a second lookup or a
two-way merge, memory holds all versions newer than the horizon, and a long-running
snapshot blocks the checkpoint from draining the map exactly as it blocks VACUUM
here. A real implementation has more to solve than this sketch: Turso logs commits to
a separate log file and tracks, per version, whether its state has been written to
the tree (`turso/core/mvcc/database/mod.rs:456-476`).
