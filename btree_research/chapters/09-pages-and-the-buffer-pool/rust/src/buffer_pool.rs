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
//! Memory: `new` allocates the frames, the frame table and the page table at
//! full capacity. Nothing allocates after that.
//!
//! Not thread-safe: one thread, no latches (latching starts in chapter 19).

use std::collections::HashMap;

use crate::pager::{INVALID_PAGE_ID, PAGE_SIZE, Page, PageId, Pager};
use crate::storage::Error;

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
            // Reserve room for one entry per frame now; it never holds more.
            page_table: HashMap::with_capacity(frame_count),
            hand: 0,
            stats: PoolStats::default(),
        }
    }

    // Dropping the pool does NOT flush: unwritten dirty pages are lost, as
    // they would be in a crash. Call `flush_all` first to keep them.

    /// Return page `id` in memory and pin it. Every fetch_page needs exactly
    /// one unpin.
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
        // If the read fails the frame simply stays empty (I2 holds).
        self.pager.read_page(id, &mut self.pages[f])?;
        self.install(f, id);
        Ok(&mut self.pages[f])
    }

    /// Allocate a new page at the end of the file and return it pinned and
    /// zero-filled. Nothing is read: a fresh page has no content to load.
    pub fn new_page(&mut self) -> Result<(PageId, &mut Page), Error> {
        // Take the frame first: if every frame is pinned we must not have
        // grown the file yet.
        let f = self.take_frame()?;
        let id = self.pager.allocate_page()?;
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
        // take_frame removed the previous occupant's entry, so this stays
        // within the capacity reserved in `new`.
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
    use crate::storage::{FileStorage, MemStorage};

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
    }

    // Zig has two allocation tests here (init under allocation failure,
    // "nothing allocates after init" with a FailingAllocator). Rust has no
    // allocator parameter to inject failures through; the fixed frame budget
    // plays that role: running out is `Err(AllFramesPinned)`, tested above.
    // What can be checked is that the page table never grows:
    #[test]
    fn the_page_table_never_grows_after_new() {
        let mut pool = pool_with_pages(&MemStorage::new(), 64, 4);
        let capacity = pool.page_table.capacity();
        let mut rng = crate::prng::SplitMix64::new(9);
        for _ in 0..2000 {
            let id = rng.below(64) as PageId;
            let dirty = rng.chance(1, 3);
            touch(&mut pool, id, dirty).unwrap();
        }
        pool.flush_all().unwrap();
        assert_eq!(pool.page_table.capacity(), capacity);
        pool.validate().unwrap();
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
    }

    #[test]
    #[should_panic(expected = "page used without a pin")]
    fn using_a_page_after_unpin_panics() {
        let mut pool = pool_with_pages(&MemStorage::new(), 2, 2);
        touch(&mut pool, 0, false).unwrap();
        let _ = pool.page(0); // cached, but not pinned any more
    }
}
