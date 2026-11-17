//! Double write: repairing a torn page with a second copy.
//!
//! A checksum tells us a page is torn; it cannot give the bytes back. The
//! double-write idea (textbook; the best-known user is InnoDB's doublewrite
//! buffer, not one of the code bases studied in this guide) is: never have
//! only one copy in flight.
//!
//! ```text
//! update(i, page):
//!   1. write the new image to slot i      then sync
//!   2. write the new image to home i      then sync
//! ```
//!
//! A crash can tear at most the copy being written, and the other copy is
//! intact: during step 1 the home page still holds the old version; during
//! step 2 the slot already holds the new version, durably.
//!
//! ```text
//! recover():  for every i
//!   slot ok                  -> home := slot (repairs a torn home page and
//!                               finishes an update that stopped between
//!                               the two steps)
//!   slot torn or blank       -> keep home (the update never got past
//!                               step 1, so home was not touched)
//! ```
//!
//! After recovery every home page is the old or the new version, never a mix:
//! a single-page write has become atomic. The price is two writes and two
//! syncs per update.
//!
//! Layout, kept deliberately trivial: logical page i has its slot at page i
//! and its home at page `slots + i`. Each copy is sealed for its own address.

use crate::page::{self, Check, PAYLOAD_SIZE};
use crate::storage::{Page, Storage, StorageError};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct RecoverReport {
    /// Home was fine and no newer slot existed.
    pub intact: u32,
    /// Home was fine but older than the slot: the update is finished.
    pub rolled_forward: u32,
    /// Home was torn (or missing) and was rebuilt from the slot.
    pub restored: u32,
    /// Neither copy was ever written.
    pub blank: u32,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RecoverError {
    Storage(StorageError),
    /// Both copies of a page are damaged.
    Unrecoverable,
}

impl From<StorageError> for RecoverError {
    fn from(err: StorageError) -> Self {
        RecoverError::Storage(err)
    }
}

pub struct DoubleWrite<'a> {
    pub storage: &'a mut dyn Storage,
    /// Number of logical pages (and of slots).
    pub slots: u64,
}

impl<'a> DoubleWrite<'a> {
    /// Scratch pages that `recover` needs.
    pub const SCRATCH_PAGES: usize = 2;

    pub fn new(storage: &'a mut dyn Storage, slots: u64) -> Self {
        Self { storage, slots }
    }

    pub fn slot_page(&self, i: u64) -> u64 {
        assert!(i < self.slots);
        i
    }

    pub fn home_page(&self, i: u64) -> u64 {
        assert!(i < self.slots);
        self.slots + i
    }

    /// Atomically replace logical page `i` with `page`'s payload. Seals the
    /// caller's buffer in place (first for the slot, then for home), so no
    /// memory is allocated. Durable when it returns.
    pub fn update(&mut self, i: u64, page: &mut Page) -> Result<(), StorageError> {
        page::seal(page, self.slot_page(i));
        self.storage.write_page(self.slot_page(i), page)?;
        // This sync is the whole trick: the home page must not be touched
        // until a complete second copy is known to be durable.
        self.storage.sync()?;
        page::seal(page, self.home_page(i));
        self.storage.write_page(self.home_page(i), page)?;
        self.storage.sync()
    }

    /// Read logical page `i` from its home and classify it.
    pub fn read(&mut self, i: u64, out: &mut Page) -> Result<Check, StorageError> {
        let home = self.home_page(i);
        page::read_checked(self.storage, home, out)
    }

    /// Run once after a crash, before anything else touches the pages.
    /// Idempotent: if recovery itself is interrupted, run it again.
    ///
    /// `scratch` provides the two page buffers (`SCRATCH_PAGES`). Zig hands
    /// in a `FixedBufferAllocator`; in Rust a borrowed slice says the same
    /// thing, and too short a slice is this function's `OutOfMemory`.
    pub fn recover(&mut self, scratch: &mut [Page]) -> Result<RecoverReport, RecoverError> {
        let [slot, home, ..] = scratch else {
            return Err(StorageError::OutOfMemory.into());
        };

        let mut report = RecoverReport::default();
        for i in 0..self.slots {
            let (slot_no, home_no) = (self.slot_page(i), self.home_page(i));
            let slot_check = page::read_checked(self.storage, slot_no, slot)?;
            let home_check = page::read_checked(self.storage, home_no, home)?;
            if slot_check == Check::Ok {
                let same = home_check == Check::Ok && slot[..PAYLOAD_SIZE] == home[..PAYLOAD_SIZE];
                if same {
                    report.intact += 1;
                    continue;
                }
                // The slot is a complete, durable image at least as new as
                // home. Copy it; if this write tears too, the slot is still
                // there for the next recovery.
                page::seal(slot, home_no);
                self.storage.write_page(home_no, slot)?;
                if home_check == Check::Ok {
                    report.rolled_forward += 1;
                } else {
                    report.restored += 1;
                }
            } else {
                match home_check {
                    // The slot write itself was torn or lost: step 2 never
                    // started, so home is the complete old version.
                    Check::Ok => report.intact += 1,
                    Check::Blank => report.blank += 1,
                    // Both copies damaged cannot happen under the protocol,
                    // which never has both in flight. If it does (bit rot, a
                    // bug), say so instead of handing out garbage.
                    Check::Corrupt => return Err(RecoverError::Unrecoverable),
                }
            }
        }
        self.storage.sync()?;
        Ok(report)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::sim_disk::{CrashMode, SimDisk};
    use crate::storage::PAGE_SIZE;

    fn payload_of(byte: u8) -> Page {
        [byte; PAGE_SIZE]
    }

    /// The byte a recovered logical page is filled with; panics if the page
    /// is not a single clean version.
    fn version_of(disk: &mut SimDisk, slots: u64, i: u64) -> u8 {
        let mut page = payload_of(0);
        assert_eq!(
            DoubleWrite::new(disk, slots).read(i, &mut page),
            Ok(Check::Ok)
        );
        let payload = &page[..PAYLOAD_SIZE];
        assert!(payload.iter().all(|&b| b == payload[0]));
        payload[0]
    }

    #[test]
    fn update_then_read_no_crash() {
        let mut disk = SimDisk::new(1);
        let mut page = payload_of(b'A');
        DoubleWrite::new(&mut disk, 2).update(1, &mut page).unwrap();
        assert_eq!(version_of(&mut disk, 2, 1), b'A');
        assert_eq!(disk.stats.writes, 2);
        assert_eq!(disk.stats.syncs, 2);

        let mut scratch = [payload_of(0); DoubleWrite::SCRATCH_PAGES];
        let report = DoubleWrite::new(&mut disk, 2)
            .recover(&mut scratch)
            .unwrap();
        assert_eq!(
            report,
            RecoverReport {
                intact: 1,
                blank: 1,
                ..Default::default()
            }
        );
    }

    #[test]
    fn crash_at_every_write_every_mode_old_or_new_never_torn() {
        let mut scratch = [payload_of(0); DoubleWrite::SCRATCH_PAGES];
        let (mut saw_old, mut saw_new, mut saw_restore) = (false, false, false);
        for mode in [
            CrashMode::Drop,
            CrashMode::Keep,
            CrashMode::Tear,
            CrashMode::Random,
        ] {
            for crash_after in 0..3 {
                // the update issues 2 writes: stop after 0, 1, 2
                for seed in 0..40 {
                    let mut disk = SimDisk::new(seed);
                    let mut page = payload_of(b'A');
                    DoubleWrite::new(&mut disk, 2).update(0, &mut page).unwrap(); // A is durable

                    disk.power_off_after_writes(crash_after);
                    page = payload_of(b'B');
                    let result = DoubleWrite::new(&mut disk, 2).update(0, &mut page);
                    assert_eq!(result, Err(StorageError::PowerLoss)); // the final sync never ran
                    disk.crash(mode);

                    let report = DoubleWrite::new(&mut disk, 2)
                        .recover(&mut scratch)
                        .unwrap();
                    saw_restore |= report.restored > 0;
                    let v = version_of(&mut disk, 2, 0);
                    assert!(v == b'A' || v == b'B');
                    if v == b'A' {
                        saw_old = true;
                    } else {
                        saw_new = true;
                    }
                    // Once the slot is durable (first sync passed) the update must win.
                    if crash_after == 2 {
                        assert_eq!(v, b'B');
                    }
                    disk.validate().unwrap();
                }
            }
        }
        assert!(saw_old && saw_new && saw_restore); // the test exercised all paths
    }

    #[test]
    fn recovery_interrupted_by_a_second_crash_still_converges() {
        let mut scratch = [payload_of(0); DoubleWrite::SCRATCH_PAGES];
        for seed in 0..200 {
            let mut disk = SimDisk::new(seed);
            let mut page = payload_of(b'A');
            DoubleWrite::new(&mut disk, 1).update(0, &mut page).unwrap();
            disk.power_off_after_writes(2);
            page = payload_of(b'B');
            let result = DoubleWrite::new(&mut disk, 1).update(0, &mut page);
            assert_eq!(result, Err(StorageError::PowerLoss));
            disk.crash(CrashMode::Tear); // home page torn, slot holds B

            disk.power_off_after_writes(1); // the repair write is accepted, its sync is not
            let result = DoubleWrite::new(&mut disk, 1).recover(&mut scratch);
            assert_eq!(result, Err(RecoverError::Storage(StorageError::PowerLoss)));
            disk.crash(CrashMode::Random);

            DoubleWrite::new(&mut disk, 1)
                .recover(&mut scratch)
                .unwrap();
            assert_eq!(version_of(&mut disk, 1, 0), b'B');
        }
    }

    #[test]
    fn recover_reports_out_of_memory_when_the_scratch_buffer_is_too_small() {
        let mut disk = SimDisk::new(1);
        let mut small = [payload_of(0); 1]; // room for one page, not two
        let result = DoubleWrite::new(&mut disk, 1).recover(&mut small);
        assert_eq!(
            result,
            Err(RecoverError::Storage(StorageError::OutOfMemory))
        );
    }

    #[test]
    fn both_copies_damaged_is_reported_not_hidden() {
        let mut disk = SimDisk::new(1);
        let garbage = payload_of(b'X'); // never sealed
        disk.write_page(0, &garbage).unwrap();
        disk.write_page(1, &garbage).unwrap();
        disk.sync().unwrap();
        let mut scratch = [payload_of(0); DoubleWrite::SCRATCH_PAGES];
        let result = DoubleWrite::new(&mut disk, 1).recover(&mut scratch);
        assert_eq!(result, Err(RecoverError::Unrecoverable));
    }
}
