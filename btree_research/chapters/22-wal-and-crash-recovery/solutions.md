# Chapter 22: solutions

Numbers below were produced by this chapter's own code. Where an answer was not run, it
says so.

## 1. Power cut at N = 4, mode `keep`

Log pages 1 to 4 are on disk. LSN 39 (bytes 4096..8216, pages 1 and 2), LSN 40 (pages 2
and 3) and LSN 41 (bytes 12336..16456, pages 3 and 4) are complete. LSN 42 runs from byte
16456 to 20576 and needs page 5, which was never written, so its checksum fails and the
scan stops. Three valid records, no commit record: the operation is ignored and the tree
is the old one. The program prints

```
N = 4: drop: before [0 records, 0 commit] | keep: before [3 records, 0 commit] | tear: before [0 records, 0 commit]
```

## 2. Checkpoint in the wrong order

With "reset the log, then write and sync the main file": the power fails after the new
log header is durable and before the main-file pages are. The log is now empty (nothing
chains from the new header), the main file still has the old pages, and the committed
operations that were only in the log are gone for good.

This was run. In a scratch copy of the Zig code the two calls in `Wal.checkpoint` were
swapped and the crash loop of part 3 (36 puts, 3-frame pool, checkpoint every 4) was
repeated. Of 212 runs per mode:

| mode | before | after | open fails | invalid | wrong contents |
|---|---|---|---|---|---|
| drop | 147 | 9 | 0 | 0 | 56 |
| keep | 111 | 45 | 43 | 4 | 9 |
| tear | 147 | 0 | 2 | 46 | 17 |
| random | 147 | 9 | 44 | 12 | 0 |

"Wrong contents" in mode `drop` is the scenario described above: a valid tree that has
lost acknowledged puts. In the other modes some main-file pages do arrive, giving the
torn trees of chapter 12. The central test asserts that these three columns are zero,
so it catches the swap.

## 3. A checkpoint after every commit

This was run (`checkpoint_every = 1`, otherwise the settings of part 3). The workload
now issues 288 page writes instead of 211, so there are 289 crash points instead of 212.
Per mode: drop 147 before / 142 after, keep 111 / 178, tear 147 / 142, random 147 / 142.

What changes: the number of writes, and with it the number of runs that end "after". The
"before" counts (147, 111, 147, 147) are the same as with a checkpoint every 4 commits:
those are the crash points inside a commit's log writes, and commits did not change. All
the extra crash points fall inside checkpoints, after the commit point, where the answer
is "after".

What cannot change: the last three columns. Open failures, invalid trees and wrong
contents stay at zero for every checkpoint policy, because the argument for atomicity
never mentions when checkpoints happen. Part 4 of the output shows the cost side: 106
main-file page writes and 110 syncs instead of 56 and 56.

## 4. Rollback

Not implemented and not run; this is a design answer.

Discarding `Wal.pending` is not enough, because uncommitted changes live in three places:

1. `Wal.pending`: pages the pool already wrote back (evictions). Clear it.
2. The buffer pool: dirty frames with uncommitted contents. They must be thrown away
   without being written, so the pool needs a "drop every dirty frame" operation; the
   next fetch re-reads the committed version through the `Wal` (index, then main file).
3. The tree handle and the pager: `key_count`, `root` and the pager's `page_count` were
   advanced by the puts. They must be reloaded from the committed metapage, and
   `page_count` must shrink back so that pages allocated by the rolled-back puts are
   handed out again.

The simplest correct implementation is close to what the chapter demands after an error
(`ReopenRequired`: close the handle, open the database again). A rollback can be cheaper
than that reopen: drop the pool and the tree handle and open them again on the same
`Wal`, after clearing `pending`. No recovery is needed, since nothing uncommitted ever
reached a file. Turso
does the equivalent: "uncommitted cached pages are discarded and cursors invalidated"
(`research/turso.md`, section 14).

## 5. A logical record for the metapage

Not implemented; a design answer.

A record "set page count to 5 and key count to 12" is still idempotent, so by itself it
could be replayed blindly. The trouble starts with records such as "add 1 to the key
count" or "insert this cell into page 2": applying them twice is wrong. Recovery then
has to know, for every page, whether a record's effect is already in the page. That
needs:

- a **page LSN** stored in each page, set to the record's LSN whenever a record is
  applied, and a redo rule "skip the record if page LSN >= record LSN"
  (Postgres: `xlogutils.c:444-445`);
- protection against torn pages, because a delta cannot be applied to a page that is
  half old and half new: a full image of the page the first time it changes after a
  checkpoint (Postgres: `xloginsert.c:698`), or a double-write buffer (chapter 21);
- a checkpoint that records where redo must start, since records before it may refer to
  page versions that no longer exist.

Also note what is lost: with full images recovery never reads the main file. With deltas
it must, so the main file's own pages have to be trustworthy (checksums) before redo can
build on them.
