// Copied from chapters/21-durability-primitives/rust/src/sim_disk.rs; only the crate:: path of the storage trait was renamed.
//! `SimDisk`: an in-memory disk that can lose power.
//!
//! It keeps two things apart that a real machine also keeps apart:
//!
//! ```text
//! durable   the bytes on the platter: what is left after a power cut
//! pending   writes the process issued that were not synced yet (on a real
//!           machine they sit in the OS page cache and the drive's cache)
//!
//! write_page(p, bytes)  append to `pending`           (durable untouched)
//! read_page(p)          newest pending write for p, else durable, else
//!                       zeroes (a hole below size()); OutOfBounds at or
//!                       beyond size()
//! sync()                apply all pending writes in order, then forget them
//! crash(mode)           decide the fate of every pending write, then forget
//! ```
//!
//! Crash modes (`CrashMode`):
//! - `Drop`: every pending write is lost
//! - `Keep`: every pending write reached the disk (the OS had flushed them)
//! - `Tear`: every pending write is torn: some of its eight 512-byte sectors
//!   are new, the others keep their old contents
//! - `Random`: each pending write independently gets one of the three fates
//!
//! All randomness comes from the SplitMix64 seeded in `new`, so a failing
//! crash test is reproduced by its seed. Draws per crash, in pending order:
//! - `Tear`: one `below(254)` per write: sector mask = 1 + draw (1..254, so
//!   never "no sector" and never "all sectors"); bit s = sector s new
//! - `Random`: one `below(3)` per write (0 drop, 1 keep, 2 tear), followed by
//!   the mask draw if the write is torn
//! - `Drop` / `Keep` draw nothing
//!
//! Crash-after-N-writes: `power_off_after_writes(n)` lets `n` more writes
//! succeed; after that every operation returns `StorageError::PowerLoss`
//! until `crash` is called, which also "reboots" the disk. A test loops
//! n = 0, 1, 2, ... to stop a multi-write operation at every possible point.
//!
//! Memory: the Zig version keeps pending writes in an arena that is reset at
//! every sync and crash. The Rust idiom for the same lifetime is a bump
//! `Vec<u8>`: page copies are appended to `pending_bytes`, write number `i`
//! lives at offset `i * PAGE_SIZE`, and `clear()` forgets them all at once
//! while keeping the capacity. Zig's allocation-failure tests are mirrored by
//! `set_pending_limit`, which makes `write_page` return `OutOfMemory`.
//!
//! One difference from Zig: Zig's `writePage` reserves the durable space its
//! write may need, so that `sync` and `crash` cannot fail for lack of memory.
//! `Vec::resize` has no error to return (it aborts the process when memory
//! runs out), so nothing is gained by reserving; the durable image grows in
//! `apply`, when a write lands.

use crate::base_page_storage::{
    PAGE_SIZE, Page, SECTOR_SIZE, SECTORS_PER_PAGE, Storage, StorageError,
};
use crate::prng::SplitMix64;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CrashMode {
    Drop,
    Keep,
    Tear,
    Random,
}

impl CrashMode {
    /// Lower-case name, as printed by the demo.
    pub fn name(self) -> &'static str {
        match self {
            CrashMode::Drop => "drop",
            CrashMode::Keep => "keep",
            CrashMode::Tear => "tear",
            CrashMode::Random => "random",
        }
    }
}

/// What `crash` did to the pending writes.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct CrashReport {
    pub dropped: u32,
    pub kept: u32,
    pub torn: u32,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct Stats {
    pub reads: u64,
    pub writes: u64,
    pub syncs: u64,
    pub crashes: u64,
}

/// `validate` found a broken internal invariant.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Invalid;

#[derive(Debug)]
pub struct SimDisk {
    /// The platter: a whole number of pages.
    durable: Vec<u8>,
    /// Bump storage for the page copies of unsynced writes, oldest first.
    pending_bytes: Vec<u8>,
    /// Page number of each unsynced write; same order as `pending_bytes`.
    pending_pages: Vec<u64>,
    prng: SplitMix64,
    /// None = power stays on. Some(n) = n more writes succeed, then PowerLoss.
    writes_left: Option<u64>,
    /// None = unlimited. Some(n) = at most n pending writes (the mirror of an
    /// allocator that runs out).
    pending_limit: Option<usize>,
    pub stats: Stats,
}

const ALL_SECTORS: u8 = 0xFF;

impl SimDisk {
    /// Largest page number + 1 this simulator accepts (256 MiB of pages).
    pub const MAX_PAGES: u64 = 1 << 16;

    pub fn new(seed: u64) -> Self {
        Self {
            durable: Vec::new(),
            pending_bytes: Vec::new(),
            pending_pages: Vec::new(),
            prng: SplitMix64::new(seed),
            writes_left: None,
            pending_limit: None,
            stats: Stats::default(),
        }
    }

    // ---- fault injection ----

    /// Let `n` more writes succeed, then fail every operation with
    /// `PowerLoss` until `crash` is called. `n = 0` fails immediately.
    pub fn power_off_after_writes(&mut self, n: u64) {
        self.writes_left = Some(n);
    }

    pub fn is_powered_off(&self) -> bool {
        self.writes_left == Some(0)
    }

    /// Allow at most `limit` pending writes; one more returns `OutOfMemory`.
    pub fn set_pending_limit(&mut self, limit: Option<usize>) {
        self.pending_limit = limit;
    }

    /// Power cut and reboot. Decides what happens to each pending write (see
    /// the file comment), empties the pending list, and turns the power back
    /// on. Afterwards reads see exactly the durable image.
    pub fn crash(&mut self, mode: CrashMode) -> CrashReport {
        let mut report = CrashReport::default();
        for i in 0..self.pending_pages.len() {
            let fate = match mode {
                CrashMode::Random => match self.prng.below(3) {
                    0 => CrashMode::Drop,
                    1 => CrashMode::Keep,
                    _ => CrashMode::Tear,
                },
                other => other,
            };
            match fate {
                CrashMode::Drop => report.dropped += 1,
                CrashMode::Keep => {
                    self.apply(i, ALL_SECTORS);
                    report.kept += 1;
                }
                CrashMode::Tear => {
                    let mask = (1 + self.prng.below(254)) as u8;
                    self.apply(i, mask);
                    report.torn += 1;
                }
                CrashMode::Random => unreachable!("resolved above"),
            }
        }
        self.forget_pending();
        self.writes_left = None;
        self.stats.crashes += 1;
        report
    }

    // ---- inspection ----

    pub fn pending_count(&self) -> usize {
        self.pending_pages.len()
    }

    pub fn durable_pages(&self) -> u64 {
        (self.durable.len() / PAGE_SIZE) as u64
    }

    /// The durable bytes of a page, ignoring pending writes: what a crash with
    /// `Drop` would leave. None if the durable image is shorter.
    pub fn durable_page(&self, page_no: u64) -> Option<&[u8]> {
        if page_no >= self.durable_pages() {
            return None;
        }
        let start = page_no as usize * PAGE_SIZE;
        Some(&self.durable[start..start + PAGE_SIZE])
    }

    /// Internal invariants; tests call this after every operation.
    pub fn validate(&self) -> Result<(), Invalid> {
        // The platter holds whole pages only.
        if !self.durable.len().is_multiple_of(PAGE_SIZE) {
            return Err(Invalid);
        }
        // One page copy per pending write, in the same order.
        if self.pending_bytes.len() != self.pending_pages.len() * PAGE_SIZE {
            return Err(Invalid);
        }
        if self.pending_pages.iter().any(|&p| p >= Self::MAX_PAGES) {
            return Err(Invalid);
        }
        // Each accepted write is either still pending or was resolved by a
        // sync or a crash, so there can never be more pending than accepted.
        if self.pending_pages.len() as u64 > self.stats.writes {
            return Err(Invalid);
        }
        Ok(())
    }

    // ---- internals ----

    /// Copy the sectors selected by `mask` (bit s = sector s) from pending
    /// write `i` onto the platter. Sectors not selected keep their old bytes;
    /// if the page did not exist yet, "old" means zeroes.
    fn apply(&mut self, i: usize, mask: u8) {
        let start = self.pending_pages[i] as usize * PAGE_SIZE;
        if self.durable.len() < start + PAGE_SIZE {
            self.durable.resize(start + PAGE_SIZE, 0);
        }
        let src = &self.pending_bytes[i * PAGE_SIZE..(i + 1) * PAGE_SIZE];
        let dst = &mut self.durable[start..start + PAGE_SIZE];
        for s in 0..SECTORS_PER_PAGE {
            if mask & (1 << s) == 0 {
                continue;
            }
            let at = s * SECTOR_SIZE;
            dst[at..at + SECTOR_SIZE].copy_from_slice(&src[at..at + SECTOR_SIZE]);
        }
    }

    fn forget_pending(&mut self) {
        // `clear` keeps the capacity: the bump area is reused by the next
        // batch of writes, like an arena reset that retains its memory.
        self.pending_bytes.clear();
        self.pending_pages.clear();
    }
}

impl Storage for SimDisk {
    fn read_page(&mut self, page_no: u64, out: &mut Page) -> Result<(), StorageError> {
        if self.is_powered_off() {
            return Err(StorageError::PowerLoss);
        }
        self.stats.reads += 1;
        // Newest pending write wins: this is the OS page cache answering.
        if let Some(i) = self.pending_pages.iter().rposition(|&p| p == page_no) {
            out.copy_from_slice(&self.pending_bytes[i * PAGE_SIZE..(i + 1) * PAGE_SIZE]);
            return Ok(());
        }
        if page_no >= self.size() {
            return Err(StorageError::OutOfBounds);
        }
        match self.durable_page(page_no) {
            Some(bytes) => out.copy_from_slice(bytes),
            // A hole: below a pending write to a higher page, but beyond the
            // end of the platter. A real file reads such a page as zeroes.
            None => out.fill(0),
        }
        Ok(())
    }

    fn write_page(&mut self, page_no: u64, page: &Page) -> Result<(), StorageError> {
        if self.is_powered_off() {
            return Err(StorageError::PowerLoss);
        }
        if page_no >= Self::MAX_PAGES {
            return Err(StorageError::OutOfBounds);
        }
        // Check the budget before touching anything, so that a refused write
        // changes nothing.
        if self
            .pending_limit
            .is_some_and(|limit| self.pending_pages.len() >= limit)
        {
            return Err(StorageError::OutOfMemory);
        }
        self.pending_bytes.extend_from_slice(page);
        self.pending_pages.push(page_no);
        self.stats.writes += 1;
        if let Some(left) = &mut self.writes_left {
            *left -= 1;
        }
        Ok(())
    }

    fn sync(&mut self) -> Result<(), StorageError> {
        if self.is_powered_off() {
            return Err(StorageError::PowerLoss);
        }
        for i in 0..self.pending_pages.len() {
            self.apply(i, ALL_SECTORS);
        }
        self.forget_pending();
        self.stats.syncs += 1;
        Ok(())
    }

    /// Pages visible to the running process (durable or pending).
    fn size(&self) -> u64 {
        let pending_end = self.pending_pages.iter().map(|&p| p + 1).max().unwrap_or(0);
        self.durable_pages().max(pending_end)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn filled(byte: u8) -> Page {
        [byte; PAGE_SIZE]
    }

    fn all(bytes: &[u8], byte: u8) -> bool {
        bytes.iter().all(|&b| b == byte)
    }

    #[test]
    fn a_write_is_visible_at_once_but_durable_only_after_sync() {
        let mut disk = SimDisk::new(1);
        let mut page = filled(0);

        disk.write_page(0, &filled(b'A')).unwrap();
        disk.read_page(0, &mut page).unwrap();
        assert!(all(&page, b'A')); // the cache answers
        assert!(disk.durable_page(0).is_none()); // the platter is empty
        assert_eq!(disk.size(), 1);

        let report = disk.crash(CrashMode::Drop);
        assert_eq!(
            report,
            CrashReport {
                dropped: 1,
                ..Default::default()
            }
        );
        assert_eq!(disk.size(), 0);
        assert_eq!(disk.read_page(0, &mut page), Err(StorageError::OutOfBounds));

        disk.write_page(0, &filled(b'A')).unwrap();
        disk.sync().unwrap();
        assert_eq!(disk.crash(CrashMode::Drop), CrashReport::default()); // nothing pending
        disk.read_page(0, &mut page).unwrap();
        assert!(all(&page, b'A'));
        disk.validate().unwrap();
    }

    #[test]
    fn keep_applies_writes_in_order_holes_read_as_zeroes() {
        let mut disk = SimDisk::new(1);
        disk.write_page(2, &filled(b'A')).unwrap();
        disk.write_page(2, &filled(b'B')).unwrap();
        let report = disk.crash(CrashMode::Keep);
        assert_eq!(
            report,
            CrashReport {
                kept: 2,
                ..Default::default()
            }
        );
        let mut page = filled(1);
        disk.read_page(2, &mut page).unwrap();
        assert!(all(&page, b'B'));
        disk.read_page(0, &mut page).unwrap();
        assert!(all(&page, 0));
        assert_eq!(disk.size(), 3);
    }

    #[test]
    fn a_hole_below_a_pending_write_reads_as_zeroes() {
        let mut disk = SimDisk::new(1);
        disk.write_page(2, &filled(b'A')).unwrap(); // not synced: the platter is empty
        assert_eq!(disk.size(), 3);
        assert_eq!(disk.durable_pages(), 0);
        let mut page = filled(0xEE);
        disk.read_page(1, &mut page).unwrap();
        assert!(all(&page, 0));
        disk.read_page(0, &mut page).unwrap();
        assert!(all(&page, 0));
        // At or beyond size() it is still an error, and `out` is left alone.
        page = filled(0xEE);
        assert_eq!(disk.read_page(3, &mut page), Err(StorageError::OutOfBounds));
        assert!(all(&page, 0xEE));
        // The hole exists only as long as the write that created it.
        disk.crash(CrashMode::Drop);
        assert_eq!(disk.read_page(1, &mut page), Err(StorageError::OutOfBounds));
    }

    #[test]
    fn a_dropped_write_to_a_far_page_leaves_no_durable_image() {
        // Zig's twin test checks its capacity reservation; here the durable
        // image only grows when a write lands.
        let mut disk = SimDisk::new(1);
        disk.write_page(0, &filled(b'A')).unwrap();
        disk.sync().unwrap();
        disk.write_page(1000, &filled(b'B')).unwrap();
        disk.crash(CrashMode::Drop);
        assert_eq!(disk.durable_pages(), 1);
        assert_eq!(
            disk.write_page(SimDisk::MAX_PAGES, &filled(b'C')),
            Err(StorageError::OutOfBounds)
        );
        disk.validate().unwrap();
    }

    #[test]
    fn a_torn_write_mixes_old_and_new_sectors_never_bytes_within_one() {
        for seed in 0..200 {
            let mut disk = SimDisk::new(seed);
            disk.write_page(0, &filled(b'A')).unwrap();
            disk.sync().unwrap();
            disk.write_page(0, &filled(b'B')).unwrap();
            let report = disk.crash(CrashMode::Tear);
            assert_eq!(
                report,
                CrashReport {
                    torn: 1,
                    ..Default::default()
                }
            );

            let page = disk.durable_page(0).unwrap();
            let mut new_sectors = 0;
            for sector in page.chunks_exact(SECTOR_SIZE) {
                let first = sector[0];
                assert!(first == b'A' || first == b'B');
                assert!(all(sector, first)); // sector is atomic
                if first == b'B' {
                    new_sectors += 1;
                }
            }
            // The mask is 1..254: at least one sector new, at least one old.
            assert!((1..SECTORS_PER_PAGE).contains(&new_sectors));
        }
    }

    #[test]
    fn the_same_seed_tears_the_same_way() {
        let image = || {
            let mut disk = SimDisk::new(21);
            disk.write_page(0, &filled(b'A')).unwrap();
            disk.sync().unwrap();
            disk.write_page(0, &filled(b'B')).unwrap();
            disk.write_page(1, &filled(b'C')).unwrap();
            disk.crash(CrashMode::Random);
            disk.write_page(0, &filled(b'D')).unwrap();
            disk.crash(CrashMode::Tear);
            disk.durable_page(0).unwrap().to_vec()
        };
        assert_eq!(image(), image());
    }

    #[test]
    fn power_goes_off_after_the_nth_write() {
        let mut disk = SimDisk::new(1);
        let mut page = filled(0);

        disk.power_off_after_writes(2);
        disk.write_page(0, &filled(b'A')).unwrap();
        disk.write_page(1, &filled(b'B')).unwrap(); // the 2nd write is accepted...
        assert!(disk.is_powered_off());
        assert_eq!(disk.sync(), Err(StorageError::PowerLoss)); // ...but never synced
        assert_eq!(
            disk.write_page(2, &filled(b'C')),
            Err(StorageError::PowerLoss)
        );
        assert_eq!(disk.read_page(0, &mut page), Err(StorageError::PowerLoss));
        assert_eq!(disk.stats.writes, 2);

        disk.crash(CrashMode::Keep); // reboot: power is back, budget is gone
        assert!(!disk.is_powered_off());
        disk.read_page(1, &mut page).unwrap();
        assert!(all(&page, b'B'));

        disk.power_off_after_writes(0); // crash before anything happens
        assert_eq!(
            disk.write_page(0, &filled(b'Z')),
            Err(StorageError::PowerLoss)
        );
        disk.validate().unwrap();
    }

    #[test]
    fn every_pending_budget_failure_in_write_page_is_clean() {
        // Mirror of Zig's checkAllAllocationFailures: run the same scenario
        // with the budget exhausted at every possible write.
        for limit in 0..2 {
            let mut disk = SimDisk::new(1);
            disk.set_pending_limit(Some(limit));
            let scenario = |disk: &mut SimDisk| -> Result<(), StorageError> {
                disk.write_page(0, &filled(b'A'))?;
                disk.write_page(3, &filled(b'B'))?;
                disk.sync()?;
                disk.write_page(1, &filled(b'C'))?;
                Ok(())
            };
            assert_eq!(scenario(&mut disk), Err(StorageError::OutOfMemory));
            disk.crash(CrashMode::Tear);
            disk.validate().unwrap();
        }
    }

    #[test]
    fn a_failed_write_leaves_the_disk_unchanged() {
        let mut disk = SimDisk::new(1);
        disk.write_page(0, &filled(b'A')).unwrap();
        disk.sync().unwrap();

        disk.set_pending_limit(Some(0)); // the very next write is refused
        assert_eq!(
            disk.write_page(7, &filled(b'B')),
            Err(StorageError::OutOfMemory)
        );
        assert_eq!(disk.pending_count(), 0);
        assert_eq!(disk.size(), 1);
        assert_eq!(disk.stats.writes, 1);
        disk.validate().unwrap();
    }

    /// Reference model for the seeded test below. `cache` is what the process
    /// should read, `durable` what must survive a crash; one byte per page is
    /// enough because every test page is filled with a single byte.
    const MODEL_PAGES: usize = 6;
    #[derive(Default)]
    struct Model {
        cache: [Option<u8>; MODEL_PAGES],
        durable: [Option<u8>; MODEL_PAGES],
        cache_size: u64,
        durable_size: u64,
    }

    #[test]
    fn seeded_model_test_write_read_sync_crash_drop_keep() {
        let mut page = filled(0);
        let mut hole_reads = 0; // reads of a hole beyond the durable end
        let mut crashes = 0;
        let mut syncs = 0;
        // Many short runs rather than one long one: the durable image never
        // shrinks, so "a hole beyond the platter" only occurs early in a run.
        for round in 0..50 {
            let mut disk = SimDisk::new(7 + round);
            let mut model = Model::default();
            let mut rng = SplitMix64::new(2121 + round);

            for _ in 0..200 {
                match rng.below(10) {
                    0..=4 => {
                        // write
                        let p = rng.below(MODEL_PAGES as u64);
                        let byte = (1 + rng.below(255)) as u8;
                        disk.write_page(p, &filled(byte)).unwrap();
                        model.cache[p as usize] = Some(byte);
                        model.cache_size = model.cache_size.max(p + 1);
                    }
                    5..=6 => {
                        // read
                        let p = rng.below(MODEL_PAGES as u64);
                        if p >= model.cache_size {
                            assert_eq!(
                                disk.read_page(p, &mut page),
                                Err(StorageError::OutOfBounds)
                            );
                        } else {
                            disk.read_page(p, &mut page).unwrap();
                            // A hole (never written, below the size) reads as zeroes.
                            assert!(all(&page, model.cache[p as usize].unwrap_or(0)));
                            if model.cache[p as usize].is_none() && p >= model.durable_size {
                                hole_reads += 1;
                            }
                        }
                    }
                    7 => {
                        // sync: the cache becomes the durable state
                        disk.sync().unwrap();
                        model.durable = model.cache;
                        model.durable_size = model.cache_size;
                    }
                    8 => {
                        // crash, nothing survives but the durable state
                        disk.crash(CrashMode::Drop);
                        model.cache = model.durable;
                        model.cache_size = model.durable_size;
                    }
                    _ => {
                        // crash, everything pending happened to reach the disk
                        disk.crash(CrashMode::Keep);
                        model.durable = model.cache;
                        model.durable_size = model.cache_size;
                    }
                }
                disk.validate().unwrap();
                assert_eq!(disk.size(), model.cache_size);
                assert_eq!(disk.durable_pages(), model.durable_size);
            }
            crashes += disk.stats.crashes;
            syncs += disk.stats.syncs;
        }
        assert!(crashes > 100 && syncs > 100);
        assert!(hole_reads >= 10); // the runs reached the case
    }

    #[test]
    fn after_a_random_crash_every_sector_is_old_or_one_of_the_pending_versions() {
        let mut page = filled(0);
        for seed in 0..300u64 {
            let mut disk = SimDisk::new(seed);
            let mut rng = SplitMix64::new(seed.wrapping_add(1000));
            // Durable state: pages 0..3 hold byte 1.
            for p in 0..4 {
                disk.write_page(p, &filled(1)).unwrap();
            }
            disk.sync().unwrap();
            // Pending: up to 6 writes with bytes 2, 3, ... on random pages.
            let mut allowed = [1u64 << 1; 4]; // bit set of bytes each page may show
            let n = 1 + rng.below(6);
            for i in 0..n {
                let p = rng.below(4);
                disk.write_page(p, &filled(2 + i as u8)).unwrap();
                allowed[p as usize] |= 1 << (2 + i);
            }
            let report = disk.crash(CrashMode::Random);
            assert_eq!(u64::from(report.dropped + report.kept + report.torn), n);
            assert_eq!(disk.pending_count(), 0);
            for p in 0..4 {
                disk.read_page(p, &mut page).unwrap();
                for sector in page.chunks_exact(SECTOR_SIZE) {
                    assert!(all(sector, sector[0]));
                    assert!(allowed[p as usize] & (1 << sector[0]) != 0);
                }
            }
        }
    }
}
