// Copied from chapters/12-disk-backed-bplus-tree/rust/src/base_buffer_pool.rs (chapter 13 uses it unchanged), which has it from:
// Copied from chapters/09-pages-and-the-buffer-pool/rust/src/buffer_pool.rs; behaviour unchanged (only the
// crate:: paths were renamed to the base_* modules of this chapter).
//! buffer_pool.rs: a fixed number of in-memory page frames in front of a Pager.
//!
//! The tree code never reads the file itself. It asks the pool for a page id
//! and receives the 4096-byte frame that holds that page:
//!
//! ```text
//! let page = pool.fetch_page(id)?;   // pins the page
//! ... read or modify page ...
//! pool.unpin(id, modified);          // dirty = true if you wrote to it
//! ```
//!
//! Three per-frame facts drive everything:
//!   pin_count   how many callers are using the frame right now. A pinned
//!               frame is never evicted.
//!   dirty       the frame differs from the file. It must be written back
//!               before the frame is reused for another page.
//!   referenced  "used since the clock hand last passed". This is the whole
//!               memory of the CLOCK eviction policy: one bit per frame.
//!
//! Invariants (checked by `validate`):
//!   I1  every non-empty frame's page id is in the page table and maps back
//!       to that frame; the table has no other entries (no page is cached twice)
//!   I2  an empty frame has pin_count 0 and is neither dirty nor referenced
//!   I3  hand < frame count
//!   I4  every cached page id is < pager.page_count()
//!
//! Difference from Zig: `fetchPage` there returns a raw pointer that stays
//! usable until `unpin`, even across other pool calls. A `&mut Page` borrowed
//! from `&mut self` cannot outlive the next call on the pool, so here the pin
//! and the borrow are separate things: `fetch_page` pins and lends the page
//! for the moment; while the pin lasts, `page(id)` / `page_mut(id)` lend it
//! again, and `page_pair_mut(a, b)` lends two pinned pages at once (a split
//! needs that). Using a page without a pin is a silent bug in Zig and a panic
//! here.
//!
//! Errors and pins. A call that returns an error leaves the pool valid and
//! takes no pin: after a failed `fetch_page` or `new_page` there is nothing to
//! unpin. Pins that the CALLER already holds are the caller's to release, on
//! the error path too. Rust has no `errdefer`, so a `?` between a fetch and
//! its unpin needs care: unpin before returning the error (see
//! `workload::run`), or wrap the pin in a guard (exercise 4).
//!
//! Difference from Zig: Zig's `deinit` asserts that no pin is left, so a
//! leaked pin fails the test that leaked it. Dropping this pool checks
//! nothing: a `Drop` that panics would turn every error returned with a pin
//! held into a panic, and without `errdefer` that is too easy to hit. The
//! tests assert `pinned_frames() == 0` themselves instead.
//!
//! A storage error is not retried. In particular a dirty victim whose
//! write-back fails stays where it is with the hand on it, so every later
//! miss that needs to evict tries the same write again and fails the same
//! way until the storage recovers: the pool stops rather than skip a page it
//! could not save.
//!
//! Memory: `new` allocates the frames, the frame table and the page table at
//! full capacity. Nothing allocates after that. The page table needs care for
//! that to be true: both std hash maps mark a removed entry with a tombstone,
//! and a pool removes and inserts one entry per eviction, forever. Zig's map
//! never clears tombstones at a fixed capacity, so the Zig pool has a
//! hand-written table. Rust's `HashMap` clears them by rehashing, in place if
//! the map is at most half full and into a NEW, larger allocation otherwise.
//! `new` therefore reserves twice the frame count.
//!
//! Not thread-safe: one thread, no latches (latching starts in chapter 19).

use std::collections::HashMap;

use crate::base_pager::{INVALID_PAGE_ID, PAGE_SIZE, Page, PageId, Pager};
use crate::base_storage::Error;

/// Bookkeeping for one frame.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Frame {
    pub page_id: PageId, // INVALID_PAGE_ID = frame is empty
    pub pin_count: u32,
    pub referenced: bool,
    pub dirty: bool,
}

impl Frame {
    const EMPTY: Frame = Frame {
        page_id: INVALID_PAGE_ID,
        pin_count: 0,
        referenced: false,
        dirty: false,
    };
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct PoolStats {
    /// fetch_page found the page in memory.
    pub hits: u64,
    /// fetch_page had to go to the pager.
    pub misses: u64,
    /// A cached page was removed to make room.
    pub evictions: u64,
    /// Evictions that first had to write a dirty page back.
    pub writebacks: u64,
}

pub struct BufferPool {
    /// Owned; borrow it with `pager()` / `pager_mut()`, get it back with
    /// `into_pager()`. (Zig's pool borrows a `*Pager` owned by the caller.)
    pager: Pager,
    /// "Boxed frames": each frame is its own 4096-byte heap allocation, made
    /// once in `new`. The Zig version carves all frames out of one
    /// page-aligned slab; safe Rust cannot ask for alignment, and does not
    /// need it because pages are only ever accessed as bytes.
    pages: Vec<Box<Page>>,
    /// Bookkeeping for frame f, parallel to `pages`.
    frames: Vec<Frame>,
    /// page id -> frame index, for the pages currently in memory.
    page_table: HashMap<PageId, usize>,
    /// The clock hand: the next frame the eviction sweep will look at.
    hand: usize,
    pub stats: PoolStats,
}

impl BufferPool {
    pub fn new(pager: Pager, frame_count: usize) -> Self {
        assert!(frame_count > 0);
        Self {
            pager,
            pages: (0..frame_count)
                .map(|_| Box::new([0u8; PAGE_SIZE]))
                .collect(),
            frames: vec![Frame::EMPTY; frame_count],
            // The table never holds more than one entry per frame. Reserving
            // twice that keeps it at most half full, which is what lets it
            // clean up after removals without ever reallocating (see the top
            // of the file).
            page_table: HashMap::with_capacity(2 * frame_count),
            hand: 0,
            stats: PoolStats::default(),
        }
    }

    // Dropping the pool does NOT flush: unwritten dirty pages are lost, as
    // they would be in a crash. Call `flush_all` first to keep them.
    // It does not check for leaked pins either (see the top of the file).

    /// Return page `id` in memory and pin it. Every successful fetch_page
    /// needs exactly one unpin; a failed one took no pin.
    pub fn fetch_page(&mut self, id: PageId) -> Result<&mut Page, Error> {
        if id >= self.pager.page_count() {
            return Err(Error::PageOutOfRange);
        }

        if let Some(&f) = self.page_table.get(&id) {
            // Hit: no I/O. Setting `referenced` is what protects a popular
            // page from the next sweep of the clock hand.
            let frame = &mut self.frames[f];
            frame.pin_count += 1;
            frame.referenced = true;
            self.stats.hits += 1;
            return Ok(&mut self.pages[f]);
        }

        // Miss: find a frame, then read the page into it.
        self.stats.misses += 1;
        let f = self.take_frame()?;
        if let Err(err) = self.pager.read_page(id, &mut self.pages[f]) {
            // Frame f stays empty (I2 holds) and whatever page take_frame
            // evicted from it stays evicted. Put the hand back on f so that
            // the next miss takes this empty frame instead of evicting a
            // second page while one frame sits unused.
            self.hand = f;
            return Err(err);
        }
        self.install(f, id);
        Ok(&mut self.pages[f])
    }

    /// Allocate a new page at the end of the file and return it pinned and
    /// zero-filled. Nothing is read: a fresh page has no content to load.
    /// On an error the file has not grown and nothing is pinned.
    pub fn new_page(&mut self) -> Result<(PageId, &mut Page), Error> {
        // Take the frame first: if every frame is pinned we must not have
        // grown the file yet.
        let f = self.take_frame()?;
        let id = match self.pager.allocate_page() {
            Ok(id) => id,
            Err(err) => {
                self.hand = f; // as in fetch_page: reuse the empty frame next
                return Err(err);
            }
        };
        self.pages[f].fill(0);
        self.install(f, id);
        Ok((id, &mut self.pages[f]))
    }

    /// Release one pin on page `id`. Pass `dirty = true` if the page was
    /// modified while pinned. The flag is sticky: a later clean unpin does not
    /// clear it; only writing the page out does.
    pub fn unpin(&mut self, id: PageId, dirty: bool) {
        let f = *self
            .page_table
            .get(&id)
            .expect("unpin of a page that is not cached");
        let frame = &mut self.frames[f];
        assert!(frame.pin_count > 0, "unpin without a matching fetch");
        frame.pin_count -= 1;
        if dirty {
            frame.dirty = true;
        }
    }

    /// The bytes of a page that is currently pinned. Panics if it is not.
    pub fn page(&self, id: PageId) -> &Page {
        &self.pages[self.pinned_frame(id)]
    }

    /// Mutable access to a pinned page. Remember to unpin it with dirty = true.
    pub fn page_mut(&mut self, id: PageId) -> &mut Page {
        let f = self.pinned_frame(id);
        &mut self.pages[f]
    }

    /// Mutable access to two different pinned pages at the same time.
    pub fn page_pair_mut(&mut self, a: PageId, b: PageId) -> (&mut Page, &mut Page) {
        let (fa, fb) = (self.pinned_frame(a), self.pinned_frame(b));
        let [pa, pb] = self
            .pages
            .get_disjoint_mut([fa, fb])
            .expect("two different pages");
        (pa, pb)
    }

    /// Write page `id` to the pager if it is cached and dirty. No sync.
    pub fn flush_page(&mut self, id: PageId) -> Result<(), Error> {
        match self.page_table.get(&id) {
            Some(&f) => self.flush_frame(f),
            None => Ok(()),
        }
    }

    /// Write every dirty page, then sync the pager once. Pages stay cached.
    pub fn flush_all(&mut self) -> Result<(), Error> {
        for f in 0..self.frames.len() {
            self.flush_frame(f)?;
        }
        self.pager.sync()
    }

    pub fn pager(&self) -> &Pager {
        &self.pager
    }

    pub fn pager_mut(&mut self) -> &mut Pager {
        &mut self.pager
    }

    /// Give the pager back, dropping the frames (without flushing).
    pub fn into_pager(self) -> Pager {
        self.pager
    }

    /// Which frame holds page `id` right now, if any (for tests and displays).
    pub fn frame_of(&self, id: PageId) -> Option<usize> {
        self.page_table.get(&id).copied()
    }

    /// The bookkeeping of every frame, in frame order.
    pub fn frames(&self) -> &[Frame] {
        &self.frames
    }

    pub fn hand(&self) -> usize {
        self.hand
    }

    pub fn frame_count(&self) -> usize {
        self.frames.len()
    }

    /// Number of frames with pin_count > 0.
    pub fn pinned_frames(&self) -> usize {
        self.frames
            .iter()
            .filter(|frame| frame.pin_count > 0)
            .count()
    }

    /// Check invariants I1 to I4 (see the top of the file).
    pub fn validate(&self) -> Result<(), &'static str> {
        let mut used = 0;
        for (f, frame) in self.frames.iter().enumerate() {
            if frame.page_id == INVALID_PAGE_ID {
                if frame.pin_count != 0 || frame.dirty || frame.referenced {
                    return Err("I2: empty frame with a pin or a flag");
                }
                continue;
            }
            used += 1;
            if self.page_table.get(&frame.page_id) != Some(&f) {
                return Err("I1: frame and page table disagree");
            }
            if frame.page_id >= self.pager.page_count() {
                return Err("I4: cached page beyond the end of the file");
            }
        }
        if self.page_table.len() != used {
            return Err("I1: page table has stale entries");
        }
        if self.hand >= self.frames.len() {
            return Err("I3: hand out of range");
        }
        Ok(())
    }

    // ---- internals -------------------------------------------------------

    fn pinned_frame(&self, id: PageId) -> usize {
        let f = *self.page_table.get(&id).expect("page is not cached");
        assert!(self.frames[f].pin_count > 0, "page used without a pin");
        f
    }

    /// Record that frame `f` (empty) now holds page `id`, pinned once.
    fn install(&mut self, f: usize, id: PageId) {
        self.frames[f] = Frame {
            page_id: id,
            pin_count: 1,
            referenced: true,
            dirty: false,
        };
        // take_frame removed the previous occupant's entry, so the table
        // holds at most frame_count entries and never grows.
        let previous = self.page_table.insert(id, f);
        debug_assert!(previous.is_none());
    }

    fn flush_frame(&mut self, f: usize) -> Result<(), Error> {
        let frame = self.frames[f];
        if frame.page_id == INVALID_PAGE_ID || !frame.dirty {
            return Ok(());
        }
        self.pager.write_page(frame.page_id, &self.pages[f])?;
        // Clear the flag only after the write succeeded.
        self.frames[f].dirty = false;
        Ok(())
    }

    /// CLOCK ("second chance"). Returns an EMPTY frame, evicting if needed.
    ///
    /// The hand sweeps the frames in a circle. At each frame:
    ///   empty               -> take it
    ///   pinned              -> skip it (and leave its referenced bit alone)
    ///   referenced          -> clear the bit and move on: its second chance
    ///   not referenced      -> victim: write it back if dirty, then evict
    ///
    /// Two full turns are enough: the first clears every unpinned frame's
    /// bit, so the second must stop at the first unpinned frame. If we get
    /// through both, every frame is pinned.
    fn take_frame(&mut self) -> Result<usize, Error> {
        let n = self.frames.len();
        for _ in 0..2 * n {
            let f = self.hand;
            let frame = self.frames[f];
            if frame.page_id != INVALID_PAGE_ID {
                if frame.pin_count > 0 {
                    self.advance_hand();
                    continue;
                }
                if frame.referenced {
                    self.frames[f].referenced = false;
                    self.advance_hand();
                    continue;
                }
                // Victim. A dirty page is the only copy of its changes: write
                // it BEFORE dropping it. If the write fails we return with the
                // frame untouched (still cached, still dirty), nothing lost.
                // The hand stays on this frame, so the next sweep retries the
                // same write: no eviction happens until it succeeds.
                if frame.dirty {
                    self.pager.write_page(frame.page_id, &self.pages[f])?;
                    self.stats.writebacks += 1;
                }
                let removed = self.page_table.remove(&frame.page_id);
                debug_assert_eq!(removed, Some(f));
                self.frames[f] = Frame::EMPTY;
                self.stats.evictions += 1;
            }
            self.advance_hand();
            return Ok(f);
        }
        Err(Error::AllFramesPinned)
    }

    fn advance_hand(&mut self) {
        self.hand = (self.hand + 1) % self.frames.len();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::TempDir;
    use crate::base_storage::{FileStorage, MemStorage};

    /// Test helper: a pool of `frames` frames over `mem` with `pages` zero pages.
    fn pool_with_pages(mem: &MemStorage, pages: u32, frames: usize) -> BufferPool {
        let mut pager = Pager::new(Box::new(mem.clone())).unwrap();
        for _ in 0..pages {
            pager.allocate_page().unwrap();
        }
        pager.stats = Default::default();
        BufferPool::new(pager, frames)
    }

    /// Test helper: fetch + unpin, i.e. "touch" a page.
    fn touch(pool: &mut BufferPool, id: PageId, dirty: bool) -> Result<(), Error> {
        let page = pool.fetch_page(id)?;
        if dirty {
            page[0] = page[0].wrapping_add(1);
        }
        pool.unpin(id, dirty);
        Ok(())
    }

    fn cached_pages(pool: &BufferPool) -> Vec<PageId> {
        pool.frames().iter().map(|frame| frame.page_id).collect()
    }

    #[test]
    fn hits_cost_no_io_misses_cost_one_read() {
        let mut pool = pool_with_pages(&MemStorage::new(), 4, 2);

        touch(&mut pool, 0, false).unwrap(); // miss
        touch(&mut pool, 0, false).unwrap(); // hit
        touch(&mut pool, 1, false).unwrap(); // miss
        touch(&mut pool, 0, false).unwrap(); // hit
        assert_eq!(
            pool.stats,
            PoolStats {
                hits: 2,
                misses: 2,
                ..Default::default()
            }
        );
        assert_eq!(pool.pager().stats.reads, 2);
        pool.validate().unwrap();
        assert_eq!(pool.fetch_page(4).err(), Some(Error::PageOutOfRange));
        assert_eq!(pool.pinned_frames(), 0);
    }

    #[test]
    fn fetch_returns_the_same_frame_while_the_page_is_cached() {
        let mut pool = pool_with_pages(&MemStorage::new(), 2, 2);

        pool.fetch_page(1).unwrap()[9] = 42;
        let a = pool.frame_of(1);
        assert_eq!(pool.fetch_page(1).unwrap()[9], 42); // second pin, same frame
        assert_eq!(pool.frame_of(1), a);
        assert_eq!(pool.frames()[0].pin_count, 2);
        pool.unpin(1, false);
        assert_eq!(pool.pinned_frames(), 1);
        pool.unpin(1, false);
        assert_eq!(pool.pinned_frames(), 0);
    }

    #[test]
    fn clock_gives_a_referenced_page_a_second_chance() {
        let mut pool = pool_with_pages(&MemStorage::new(), 8, 3);

        // Fill: frames [0 1 2], all referenced, hand back at 0.
        for id in 0..3 {
            touch(&mut pool, id, false).unwrap();
        }
        assert_eq!(pool.hand(), 0);

        // Page 3: the sweep clears all three bits, comes round, evicts frame 0.
        touch(&mut pool, 3, false).unwrap();
        assert_eq!(cached_pages(&pool), [3, 1, 2]);
        assert_eq!(pool.hand(), 1);

        // Touch page 1: its bit is set again. Page 2's bit is still clear.
        touch(&mut pool, 1, false).unwrap();
        // Page 4: the hand is at frame 1 (page 1, referenced): second chance.
        // Frame 2 (page 2, not referenced) is the victim.
        touch(&mut pool, 4, false).unwrap();
        assert_eq!(cached_pages(&pool), [3, 1, 4]);
        assert!(!pool.frames()[1].referenced); // the chance was used up
        assert_eq!(pool.hand(), 0);
        assert_eq!(pool.stats.evictions, 2);
        pool.validate().unwrap();
        assert_eq!(pool.pinned_frames(), 0);
    }

    #[test]
    fn pinned_pages_are_never_evicted_all_pinned_is_an_error() {
        let mut pool = pool_with_pages(&MemStorage::new(), 4, 2);

        pool.fetch_page(0).unwrap()[100] = 7; // stays pinned
        touch(&mut pool, 1, false).unwrap();
        touch(&mut pool, 2, false).unwrap(); // must evict page 1, not the pinned page 0
        assert_eq!(cached_pages(&pool), [0, 2]);
        assert_eq!(pool.page(0)[100], 7); // still there, still ours

        pool.fetch_page(2).unwrap(); // now both frames are pinned
        let before = pool.stats;
        assert_eq!(pool.fetch_page(3).err(), Some(Error::AllFramesPinned));
        assert_eq!(pool.new_page().err(), Some(Error::AllFramesPinned));
        // The failed fetch changed nothing except the miss counter.
        assert_eq!(cached_pages(&pool), [0, 2]);
        assert_eq!(pool.stats.evictions, before.evictions);
        assert_eq!(pool.pager().page_count(), 4); // new_page did not grow the file
        pool.validate().unwrap();

        pool.unpin(2, false);
        touch(&mut pool, 3, false).unwrap(); // works again
        pool.unpin(0, true);
        assert_eq!(pool.pinned_frames(), 0);
    }

    #[test]
    fn a_dirty_page_is_written_back_when_evicted_a_clean_one_is_not() {
        let mem = MemStorage::new();
        let mut pool = pool_with_pages(&mem, 4, 1);

        pool.fetch_page(0).unwrap()[..5].copy_from_slice(b"dirty");
        pool.unpin(0, true);
        // Still only in memory: the storage has zeroes.
        assert_eq!(&mem.bytes()[..5], [0; 5]);

        touch(&mut pool, 1, false).unwrap(); // evicts page 0 -> write back
        assert_eq!(pool.pager().stats.writes, 1);
        assert_eq!(pool.stats.writebacks, 1);
        assert_eq!(&mem.bytes()[..5], b"dirty");

        touch(&mut pool, 2, false).unwrap(); // evicts clean page 1 -> no write
        assert_eq!(pool.pager().stats.writes, 1);
        assert_eq!(pool.stats.evictions, 2);

        // Reading page 0 again brings the modified bytes back from storage.
        assert_eq!(&pool.fetch_page(0).unwrap()[..5], b"dirty");
        pool.unpin(0, false);
        assert_eq!(pool.pinned_frames(), 0);
    }

    #[test]
    fn the_dirty_flag_is_sticky_across_a_clean_unpin() {
        let mut pool = pool_with_pages(&MemStorage::new(), 2, 2);

        touch(&mut pool, 0, true).unwrap();
        touch(&mut pool, 0, false).unwrap(); // a reader comes later; still dirty
        assert!(pool.frames()[0].dirty);
        pool.flush_page(0).unwrap();
        assert!(!pool.frames()[0].dirty);
        assert_eq!(pool.pager().stats.writes, 1);
        pool.flush_page(0).unwrap(); // clean: nothing to write
        pool.flush_page(1).unwrap(); // not cached: nothing to write
        assert_eq!(pool.pager().stats.writes, 1);
        assert_eq!(pool.pinned_frames(), 0);
    }

    #[test]
    fn flush_all_writes_dirty_pages_once_and_syncs_data_survives_reopen() {
        let tmp = TempDir::new("pool_reopen");
        let path = tmp.0.join("pool.db");
        {
            let pager = Pager::new(Box::new(FileStorage::create(&path).unwrap())).unwrap();
            let mut pool = BufferPool::new(pager, 4);

            for i in 0..3u64 {
                let (id, page) = pool.new_page().unwrap();
                assert_eq!(u64::from(id), i);
                assert!(page.iter().all(|&b| b == 0));
                page[..8].copy_from_slice(&(1000 + i).to_le_bytes());
                pool.unpin(id, true);
            }
            pool.flush_all().unwrap();
            assert_eq!(pool.pager().stats.writes, 3);
            assert_eq!(pool.pager().stats.syncs, 1);
            pool.flush_all().unwrap(); // nothing dirty any more
            assert_eq!(pool.pager().stats.writes, 3);
            pool.validate().unwrap();
            assert_eq!(pool.pinned_frames(), 0);
        }

        let pager = Pager::new(Box::new(FileStorage::open(&path).unwrap())).unwrap();
        assert_eq!(pager.page_count(), 3);
        let mut pool = BufferPool::new(pager, 2);
        for i in 0..3u32 {
            let page = pool.fetch_page(i).unwrap();
            assert_eq!(
                u64::from_le_bytes(page[..8].try_into().unwrap()),
                1000 + u64::from(i)
            );
            pool.unpin(i, false);
        }
        assert_eq!(pool.pinned_frames(), 0);
    }

    #[test]
    fn without_a_flush_dirty_pages_are_lost_drop_is_not_a_checkpoint() {
        let mem = MemStorage::new();
        {
            let mut pool = pool_with_pages(&mem, 1, 2);
            touch(&mut pool, 0, true).unwrap();
        }
        assert!(mem.bytes().iter().all(|&b| b == 0));
    }

    #[test]
    fn a_failed_write_back_keeps_the_page_cached_and_dirty() {
        let mem = MemStorage::new();
        let mut pool = pool_with_pages(&mem, 3, 1);

        touch(&mut pool, 0, true).unwrap();
        mem.set_writes_before_failure(Some(0));
        assert_eq!(pool.fetch_page(1).err(), Some(Error::StorageFailure));
        assert_eq!(pool.flush_all(), Err(Error::StorageFailure));
        // Page 0 is still here with its change; nothing was dropped.
        assert_eq!(pool.frames()[0].page_id, 0);
        assert!(pool.frames()[0].dirty);
        assert_eq!(pool.stats.evictions, 0);
        pool.validate().unwrap();

        mem.set_writes_before_failure(None); // the disk recovers
        touch(&mut pool, 1, false).unwrap();
        assert_eq!(mem.bytes()[0], 1);
        assert_eq!(pool.pinned_frames(), 0);
    }

    #[test]
    fn a_victim_that_cannot_be_written_blocks_eviction_until_the_storage_recovers() {
        let mem = MemStorage::new();
        let mut pool = pool_with_pages(&mem, 4, 2);

        touch(&mut pool, 0, true).unwrap(); // dirty
        touch(&mut pool, 1, false).unwrap(); // clean
        mem.set_writes_before_failure(Some(0));
        // The sweep reaches dirty page 0 first. Clean page 1 could be evicted
        // without any write, but the pool does not skip a page it failed to save.
        assert_eq!(pool.fetch_page(2).err(), Some(Error::StorageFailure));
        assert_eq!(pool.fetch_page(3).err(), Some(Error::StorageFailure));
        assert_eq!(cached_pages(&pool), [0, 1]);
        assert_eq!(pool.hand(), 0);
        assert!(pool.frames()[0].dirty);
        pool.validate().unwrap();
        // Pages that are cached are still served.
        touch(&mut pool, 1, false).unwrap();

        mem.set_writes_before_failure(None);
        touch(&mut pool, 2, false).unwrap();
        assert_eq!(cached_pages(&pool), [2, 1]);
        assert_eq!(mem.bytes()[0], 1); // page 0 reached the storage
        assert_eq!(pool.pinned_frames(), 0);
    }

    #[test]
    fn a_failed_read_leaves_an_empty_frame_that_the_next_miss_reuses() {
        let mem = MemStorage::new();
        let mut pool = pool_with_pages(&mem, 6, 2);

        touch(&mut pool, 0, true).unwrap();
        touch(&mut pool, 1, true).unwrap();
        mem.set_reads_before_failure(Some(0));
        // The miss evicts page 0 (written back first), then the read fails.
        assert_eq!(pool.fetch_page(2).err(), Some(Error::StorageFailure));
        assert_eq!(cached_pages(&pool), [INVALID_PAGE_ID, 1]);
        assert_eq!(pool.hand(), 0); // back on the empty frame
        assert_eq!(pool.pinned_frames(), 0); // the failed fetch took no pin
        assert_eq!(pool.frame_of(2), None);
        pool.validate().unwrap();
        assert_eq!(mem.bytes()[0], 1); // the evicted page was saved

        mem.set_reads_before_failure(None);
        touch(&mut pool, 3, false).unwrap();
        // Page 3 went into the empty frame; page 1 was not evicted for it.
        assert_eq!(cached_pages(&pool), [3, 1]);
        assert_eq!(pool.stats.evictions, 1);
        assert_eq!(pool.stats.writebacks, 1);
        pool.validate().unwrap();
    }

    #[test]
    fn a_failed_new_page_neither_grows_the_file_nor_wastes_a_frame() {
        let mem = MemStorage::new();
        let mut pool = pool_with_pages(&mem, 3, 2);

        touch(&mut pool, 0, false).unwrap();
        touch(&mut pool, 1, false).unwrap();
        mem.set_writes_before_failure(Some(0)); // growing the file fails
        assert_eq!(pool.new_page().err(), Some(Error::StorageFailure));
        assert_eq!(pool.pager().page_count(), 3);
        assert_eq!(pool.pinned_frames(), 0);
        assert_eq!(cached_pages(&pool), [INVALID_PAGE_ID, 1]);
        pool.validate().unwrap();

        mem.set_writes_before_failure(None);
        let (id, _) = pool.new_page().unwrap(); // the retry uses the empty frame
        assert_eq!(id, 3);
        assert_eq!(cached_pages(&pool), [3, 1]);
        assert_eq!(pool.stats.evictions, 1);
        pool.unpin(id, true);
        assert_eq!(pool.pinned_frames(), 0);
    }

    /// The shape every multi-page operation in later chapters has: hold one
    /// pin, then do something that can fail. Zig writes this with `defer` and
    /// `errdefer`; here every early return unpins by hand.
    fn copy_first_byte(pool: &mut BufferPool, from: PageId, to: PageId) -> Result<(), Error> {
        pool.fetch_page(from)?;
        if let Err(err) = pool.fetch_page(to) {
            pool.unpin(from, false); // the fetch failed while `from` was pinned
            return Err(err);
        }
        let (src, dst) = pool.page_pair_mut(from, to);
        let ok = src[0] != 0xFF; // stands for any failure with both pinned
        if ok {
            dst[0] = src[0];
        }
        pool.unpin(to, ok); // dirty only if it was changed
        pool.unpin(from, false);
        if ok { Ok(()) } else { Err(Error::CorruptFile) }
    }

    #[test]
    fn the_callers_pins_are_released_when_a_later_step_fails() {
        let mem = MemStorage::new();
        let mut pool = pool_with_pages(&mem, 4, 2);

        mem.set_reads_before_failure(Some(1)); // the first fetch works, the second not
        assert_eq!(copy_first_byte(&mut pool, 0, 1), Err(Error::StorageFailure));
        assert_eq!(pool.pinned_frames(), 0);
        mem.set_reads_before_failure(None);

        pool.fetch_page(0).unwrap()[0] = 0xFF;
        pool.unpin(0, true);
        assert_eq!(copy_first_byte(&mut pool, 0, 1), Err(Error::CorruptFile));
        assert_eq!(pool.pinned_frames(), 0);
        let f1 = pool.frame_of(1).unwrap();
        assert!(!pool.frames()[f1].dirty); // released clean

        copy_first_byte(&mut pool, 2, 1).unwrap();
        assert_eq!(pool.pinned_frames(), 0);
    }

    // Zig has a test of its hand-written page table here, and two allocation
    // tests (init under allocation failure, "nothing allocates after init"
    // with a FailingAllocator). Rust uses std's HashMap and has no allocator
    // parameter to inject failures through; the fixed frame budget plays that
    // role: running out is `Err(AllFramesPinned)`, tested above. What can be
    // checked is that the page table never grows, however many pages pass
    // through it. `capacity()` is "entries + room left"; tombstones use up
    // room, so it dips below its first value and comes back when the map
    // rehashes in place. It can only EXCEED its first value if the map moved
    // to a larger allocation, and right after such a move it always does.
    #[test]
    fn the_page_table_never_grows_after_new() {
        let mut pool = pool_with_pages(&MemStorage::new(), 64, 4);
        let capacity = pool.page_table.capacity();
        let mut rng = crate::prng::SplitMix64::new(9);
        for _ in 0..2000 {
            let id = rng.below(64) as PageId;
            let dirty = rng.chance(1, 3);
            touch(&mut pool, id, dirty).unwrap();
            assert!(pool.page_table.capacity() <= capacity);
        }
        pool.flush_all().unwrap();
        pool.validate().unwrap();
    }

    #[test]
    fn the_page_table_does_not_grow_while_the_pool_cycles_through_many_pages() {
        // 100 frames: with room for only 100 entries the map was more than
        // half full, could not rehash in place and reallocated.
        let mut pool = pool_with_pages(&MemStorage::new(), 2000, 100);
        let capacity = pool.page_table.capacity();
        for _ in 0..3 {
            for id in 0..2000 {
                touch(&mut pool, id, false).unwrap();
                assert!(pool.page_table.capacity() <= capacity);
            }
        }
        pool.validate().unwrap();
        assert_eq!(pool.page_table.len(), 100);
        assert_eq!(pool.stats.evictions, 5900);
    }

    #[test]
    fn page_accessors_lend_pinned_pages_two_at_once() {
        let mut pool = pool_with_pages(&MemStorage::new(), 4, 2);
        pool.fetch_page(0).unwrap();
        pool.fetch_page(1).unwrap();
        // Move a byte from page 0 to page 1, as a split moves cells.
        pool.page_mut(0)[0] = 9;
        let (left, right) = pool.page_pair_mut(0, 1);
        right[0] = left[0];
        left[0] = 0;
        assert_eq!((pool.page(0)[0], pool.page(1)[0]), (0, 9));
        pool.unpin(0, true);
        pool.unpin(1, true);
        assert_eq!(pool.pinned_frames(), 0);
    }

    #[test]
    #[should_panic(expected = "page used without a pin")]
    fn using_a_page_after_unpin_panics() {
        let mut pool = pool_with_pages(&MemStorage::new(), 2, 2);
        touch(&mut pool, 0, false).unwrap();
        let _ = pool.page(0); // cached, but not pinned any more
    }
}
