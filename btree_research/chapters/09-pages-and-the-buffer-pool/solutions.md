# Chapter 09: solutions

## 1. Trace by hand (easy)

Three frames, pages 1, 2, 3, 1, 4, 1, 5, 2, 1, each fetched and released at once.
`R` marks a set referenced bit; the last column is the hand after the fetch.

| Fetch | Result | f0 | f1 | f2 | Hand |
|---|---|---|---|---|---|
| 1 | miss, empty f0 | 1 R | | | 1 |
| 2 | miss, empty f1 | 1 R | 2 R | | 2 |
| 3 | miss, empty f2 | 1 R | 2 R | 3 R | 0 |
| 1 | hit | 1 R | 2 R | 3 R | 0 |
| 4 | miss: the sweep clears all three bits, evicts page 1 (f0) | 4 R | 2 | 3 | 1 |
| 1 | miss: f1 has no bit, evict page 2 | 4 R | 1 R | 3 | 2 |
| 5 | miss: f2 has no bit, evict page 3 | 4 R | 1 R | 5 R | 0 |
| 2 | miss: clears all three bits, evicts page 4 (f0) | 2 R | 1 | 5 | 1 |
| 1 | hit | 2 R | 1 R | 5 | 1 |

Totals: 2 hits, 7 misses, 4 evictions; final frames 2, 1, 5 with the hand at frame 1.

The lesson is in row 5: the hit on page 1 just before did not protect it. When every
frame has its bit set, the first sweep clears them all and evicts whatever the hand
started on. One bit can say "used since the hand passed" but not "used more recently
than the others".

In the visualization: set frames to 3, press Reset, and type the page numbers one by
one with "release at once" ticked.

## 2. Write before unmapping (easy)

With the two steps swapped, `takeFrame` removes the victim from the page table and then
tries to write it. If the write fails it returns the error with the frame still holding
the page (`page_id` set, dirty) but with no page-table entry.

The test "a failed write-back keeps the page cached and dirty" fails at
`try pool.validate()` (invariant I1: a non-empty frame must be in the page table).

What a user would lose: the modified page is now unreachable. The next `fetchPage` for
that id is a miss and reads the old version from the file into another frame, so the
change has silently disappeared from every reader's view, and two frames claim the same
page. The rule the original order follows: never destroy the in-memory state that lets
you retry until the I/O it depends on has succeeded. The same rule is why `flushFrame`
clears `dirty` after the write and why `allocatePage` bumps `page_count` after it.

## 3. A counter instead of a bit (medium)

Change `referenced: bool` to `ref_count: u2` (Rust: `u8`).

- On a hit and on install: `if (frame.ref_count < 3) frame.ref_count += 1;` (install can
  start at 1).
- In the sweep, the middle case becomes
  `if (frame.ref_count > 0) { frame.ref_count -= 1; advance; continue; }`.

A page fetched three times now survives three visits of the hand, so a page that is hot
is told apart from one that was touched once. That is what the single bit could not do
in exercise 1.

Bound: an unpinned frame can be passed at most 3 times before its counter is 0, and is
taken on the next visit. So `4 * frame_count` steps without finding a victim proves that
every frame is pinned. In general `(max + 1) * frame_count`. Turso uses exactly this
bound: `max_examinations = len * (REF_MAX + 1)` in `evict_one`
(`turso/core/storage/page_cache.rs:674-740`), and Postgres notes that a sweep can take
`BM_MAX_USAGE_COUNT + 1` complete cycles (`postgres/src/include/storage/buf_internals.h:136-144`).

The cost is that eviction can take up to four turns instead of two, and a page that was
hot long ago needs several sweeps to cool down.

## 4. Pin guards (medium)

Zig has no destructors; the idiom is `defer` right after the fetch:

```zig
const page = try pool.fetchPage(id);
defer pool.unpin(id, false);          // read-only use
```

For a page that may be modified, keep the flag in a variable that the deferred call
reads when the scope ends:

```zig
const page = try pool.fetchPage(id);
var dirty = false;
defer pool.unpin(id, dirty);
if (needsChange(page)) {
    change(page);
    dirty = true;
}
```

In Rust the natural design is a guard that unpins in `Drop`:

```rust
pub struct PinGuard<'a> {
    pool: &'a mut BufferPool,
    id: PageId,
    dirty: bool,
}

impl<'a> PinGuard<'a> {
    pub fn new(pool: &'a mut BufferPool, id: PageId) -> Result<Self, Error> {
        pool.fetch_page(id)?;
        Ok(Self { pool, id, dirty: false })
    }
    pub fn page(&self) -> &Page { self.pool.page(self.id) }
    pub fn page_mut(&mut self) -> &mut Page {
        self.dirty = true;
        self.pool.page_mut(self.id)
    }
}

impl Drop for PinGuard<'_> {
    fn drop(&mut self) { self.pool.unpin(self.id, self.dirty); }
}
```

This compiles and works for one page at a time, and that is its limit: the guard holds
`&mut BufferPool`, so while it lives nobody else can call the pool. A tree descent needs
the parent pinned while it fetches the child; a split needs two or three pages pinned
together. Two guards would be two `&mut` borrows of the same pool, which the borrow
checker rejects.

Ways out, each with a price:

- Keep pins logical, as this chapter does: `fetch_page` / `unpin` by id, short borrows
  through `page(id)`. No guard, so a pin can be forgotten (the model test checks
  `pinned_frames() == 0` at the end).
- Give the pool interior mutability: `fetch` takes `&self`, frames are
  `Rc<RefCell<Page>>` or the bookkeeping sits in a `RefCell`, and the guard holds
  `&BufferPool`. Many guards can then coexist; the borrow checks move to run time. This
  is the shape of Turso's `PinGuard`, which wraps a reference-counted page and unpins in
  `Drop` (`turso/core/storage/btree.rs:409-437`).

## 5. A scan flushes the hot pages (hard)

Experiment. A pool of `n` frames; a small set of hot pages H (fewer than `n`) that is
fetched constantly; then one scan that fetches each of `2n` cold pages once, with no hot
access in between.

What happens can be derived from the algorithm. Every scan fetch is a miss. Newly loaded
pages get `referenced = true`, exactly like the hot ones, so the pool cannot tell them
apart. The first scan miss sweeps a full circle, clearing every bit, and evicts one
page. From then on every frame holding an old page has a clear bit, and each further
miss evicts the next such frame the hand reaches. After at most `n` scan misses every
hot page is gone, and the pool is full of pages that will never be used again. When the
normal workload resumes it pays one miss per hot page to bring them back. Counters to
watch: `evictions` grows by about `2n` during the scan, and `misses` jumps by `|H|`
right after it. You can reproduce it in the visualization: fetch 0, 1, 0, 1, 0, 1 and
then 2, 3, 4, 5, 6, 7 with four frames.

Fixes, from simple to elaborate:

1. **Load scan pages cold.** Add a fetch variant for scans that installs the page with
   `referenced = false` and does not set the bit on a hit. A scan page is then the first
   victim of the next sweep, so the scan recycles its own frames and the hot pages keep
   theirs. One extra parameter, no new data structure.
2. **Give scans their own small ring of frames.** The scan reuses a handful of frames
   round-robin and never takes part in the main clock. (Textbook idea. What the sources
   show is only the hook for it: Postgres's `PinBuffer` takes an optional access
   strategy, and only the default case, no strategy, bumps the usage count:
   `postgres/src/backend/storage/buffer/bufmgr.c:3338-3342`.)
3. **Count more than one bit** (exercise 3). A hot page with count 3 survives three
   sweeps; a scan page loaded with count 1 survives one. This reduces the damage without
   removing it: a scan longer than three turns of the clock still wins.

Textbook alternatives not verified in the sources: LRU-K and 2Q, which admit a page to
the protected part of the cache only on its second reference.
