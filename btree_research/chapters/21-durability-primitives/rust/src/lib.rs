//! Chapter 21: durability primitives. The demo program (`run`) and the
//! modules it is built from.
//!
//! Five small experiments on a simulated disk (seed 2121 for the walk-through):
//!   1. a write is visible immediately but durable only after sync
//!   2. a torn write, and the checksum that catches it
//!   3. the checksum also binds a page to its address
//!   4. double write: a second copy turns "detected" into "repaired"
//!   5. crash at every write, in every mode, for 100 seeds: count the outcomes
//!
//! Demo pages are filled with one letter ('A' = old version, 'B' = new) so a
//! page can be shown as eight characters, one per 512-byte sector.

use std::io::{self, Write};

pub mod crc32;
pub mod doublewrite;
pub mod file_storage;
pub mod page;
pub mod prng;
pub mod sim_disk;
pub mod storage;

use doublewrite::DoubleWrite;
use page::Check;
use sim_disk::{CrashMode, SimDisk};
use storage::{PAGE_SIZE, Page, SECTOR_SIZE, SECTORS_PER_PAGE, Storage, StorageError};

const DEMO_SEED: u64 = 2121;

/// A page whose payload is all `letter`, sealed for `page_no`.
fn sealed_page(letter: u8, page_no: u64) -> Page {
    let mut page = [letter; PAGE_SIZE];
    page::seal(&mut page, page_no);
    page
}

/// One character per sector: 'A' or 'B' if the sector equals that sector of
/// the sealed A or B image for this address, '.' if it is all zeroes, '?'
/// otherwise.
fn sector_map(page: &Page, page_no: u64) -> String {
    let mut map = String::with_capacity(SECTORS_PER_PAGE);
    for s in 0..SECTORS_PER_PAGE {
        let range = s * SECTOR_SIZE..(s + 1) * SECTOR_SIZE;
        let sector = &page[range.clone()];
        let mut c = '?';
        if sector.iter().all(|&b| b == 0) {
            c = '.';
        }
        for letter in *b"AB" {
            if sector == &sealed_page(letter, page_no)[range.clone()] {
                c = letter as char;
            }
        }
        map.push(c);
    }
    map
}

/// The demo never expects a storage error; turn one into an I/O error so
/// `run` has a single error type.
fn io_err(err: StorageError) -> io::Error {
    io::Error::other(format!("{err:?}"))
}

fn print_read(w: &mut dyn Write, storage: &mut dyn Storage, page_no: u64) -> io::Result<()> {
    let mut page = [0u8; PAGE_SIZE];
    match storage.read_page(page_no, &mut page) {
        Err(StorageError::OutOfBounds) => {
            let size = storage.size();
            writeln!(w, "read  page {page_no} -> out of bounds (size={size})")
        }
        Err(err) => Err(io_err(err)),
        Ok(()) => {
            let map = sector_map(&page, page_no);
            let check = page::verify(&page, page_no).name();
            writeln!(w, "read  page {page_no} -> {map} {check}")
        }
    }
}

fn print_crash(w: &mut dyn Write, disk: &mut SimDisk, mode: CrashMode) -> io::Result<()> {
    let r = disk.crash(mode);
    writeln!(
        w,
        "crash({}): dropped={} kept={} torn={}",
        mode.name(),
        r.dropped,
        r.kept,
        r.torn
    )
}

/// The naive update: overwrite the page where it lives.
fn update_in_place(
    storage: &mut dyn Storage,
    page_no: u64,
    page: &mut Page,
) -> Result<(), StorageError> {
    page::seal(page, page_no);
    storage.write_page(page_no, page)?;
    storage.sync()
}

#[derive(Debug, Default)]
struct Outcome {
    old: u32,
    new: u32,
    corrupt: u32,
}

impl Outcome {
    fn count(&mut self, check: Check, page: &Page) {
        if check != Check::Ok {
            self.corrupt += 1;
        } else if page[0] == b'A' {
            self.old += 1;
        } else {
            self.new += 1;
        }
    }
}

const MODES: [CrashMode; 4] = [
    CrashMode::Drop,
    CrashMode::Keep,
    CrashMode::Tear,
    CrashMode::Random,
];
const SEEDS_PER_CELL: u64 = 100;

/// A crashed update may only fail with `PowerLoss`.
fn expect_power_loss(result: Result<(), StorageError>) -> Result<(), StorageError> {
    match result {
        Ok(()) | Err(StorageError::PowerLoss) => Ok(()),
        Err(err) => Err(err),
    }
}

/// Experiment 5a: page 0 holds A durably; overwrite it with B in place, lose
/// power after `crash_after` writes, crash in every mode, look at the page.
fn in_place_outcomes(crash_after: u64) -> Result<Outcome, StorageError> {
    let mut outcome = Outcome::default();
    for mode in MODES {
        for seed in 0..SEEDS_PER_CELL {
            let mut disk = SimDisk::new(seed);
            let mut page = [b'A'; PAGE_SIZE];
            update_in_place(&mut disk, 0, &mut page)?;

            disk.power_off_after_writes(crash_after);
            page = [b'B'; PAGE_SIZE];
            expect_power_loss(update_in_place(&mut disk, 0, &mut page))?;
            disk.crash(mode);
            let check = page::read_checked(&mut disk, 0, &mut page)?;
            outcome.count(check, &page);
        }
    }
    Ok(outcome)
}

/// Experiment 5b: the same, through DoubleWrite, looking after `recover`.
fn double_write_outcomes(crash_after: u64) -> Result<Outcome, StorageError> {
    let mut outcome = Outcome::default();
    // Recovery's two page buffers: a fixed, known amount of memory that is
    // reused for every run.
    let mut scratch = [[0u8; PAGE_SIZE]; DoubleWrite::SCRATCH_PAGES];
    for mode in MODES {
        for seed in 0..SEEDS_PER_CELL {
            let mut disk = SimDisk::new(seed);
            let mut page = [b'A'; PAGE_SIZE];
            DoubleWrite::new(&mut disk, 1).update(0, &mut page)?;

            disk.power_off_after_writes(crash_after);
            page = [b'B'; PAGE_SIZE];
            expect_power_loss(DoubleWrite::new(&mut disk, 1).update(0, &mut page))?;
            disk.crash(mode);
            let mut dw = DoubleWrite::new(&mut disk, 1);
            // Unrecoverable cannot happen here; report it as corruption if it does.
            let recovered = dw.recover(&mut scratch).is_ok();
            let check = dw.read(0, &mut page)?;
            outcome.count(if recovered { check } else { Check::Corrupt }, &page);
        }
    }
    Ok(outcome)
}

pub fn run(w: &mut dyn Write) -> io::Result<()> {
    writeln!(w, "Chapter 21: durability primitives")?;
    writeln!(
        w,
        "page = 4096 bytes = 8 sectors of 512; one letter per sector; SimDisk seed 2121"
    )?;

    // ---- 1 and 2 share one disk ----
    let mut disk = SimDisk::new(DEMO_SEED);

    writeln!(w, "\n== 1. A write is not durable until sync ==")?;
    let mut page = sealed_page(b'A', 0);
    disk.write_page(0, &page).map_err(io_err)?;
    let (pending, durable) = (disk.pending_count(), disk.durable_pages());
    writeln!(
        w,
        "write page 0 = A: pending={pending} durable_pages={durable}"
    )?;
    print_read(w, &mut disk, 0)?;
    print_crash(w, &mut disk, CrashMode::Drop)?;
    print_read(w, &mut disk, 0)?;
    disk.write_page(0, &page).map_err(io_err)?;
    disk.sync().map_err(io_err)?;
    let (pending, durable) = (disk.pending_count(), disk.durable_pages());
    writeln!(
        w,
        "write page 0 = A, sync: pending={pending} durable_pages={durable}"
    )?;
    print_crash(w, &mut disk, CrashMode::Drop)?;
    print_read(w, &mut disk, 0)?;

    writeln!(w, "\n== 2. A torn write, caught by the checksum ==")?;
    page = sealed_page(b'B', 0);
    disk.write_page(0, &page).map_err(io_err)?;
    let (pending, durable) = (disk.pending_count(), disk.durable_pages());
    writeln!(
        w,
        "write page 0 = B: pending={pending} durable_pages={durable}"
    )?;
    print_read(w, &mut disk, 0)?;
    print_crash(w, &mut disk, CrashMode::Tear)?;
    print_read(w, &mut disk, 0)?;
    disk.read_page(0, &mut page).map_err(io_err)?;
    writeln!(
        w,
        "checksum: stored={:08x} computed={:08x}",
        page::stored_checksum(&page),
        page::checksum(&page, 0)
    )?;

    writeln!(w, "\n== 3. The checksum binds a page to its address ==")?;
    page = sealed_page(b'A', 0);
    writeln!(
        w,
        "page sealed for address 0: checksum={:08x}",
        page::stored_checksum(&page)
    )?;
    writeln!(
        w,
        "verified at address 0: {}",
        page::verify(&page, 0).name()
    )?;
    writeln!(
        w,
        "verified at address 1: {} (expected checksum {:08x})",
        page::verify(&page, 1).name(),
        page::checksum(&page, 1)
    )?;

    writeln!(
        w,
        "\n== 4. Double write: a second copy makes repair possible =="
    )?;
    {
        let mut disk2 = SimDisk::new(DEMO_SEED);
        {
            let dw = DoubleWrite::new(&mut disk2, 1);
            let (slot, home) = (dw.slot_page(0), dw.home_page(0));
            writeln!(w, "layout: slot = page {slot}, home = page {home}")?;
        }
        page = [b'A'; PAGE_SIZE];
        DoubleWrite::new(&mut disk2, 1)
            .update(0, &mut page)
            .map_err(io_err)?;
        let stats = disk2.stats;
        writeln!(
            w,
            "update to A: writes={} syncs={}",
            stats.writes, stats.syncs
        )?;
        disk2.power_off_after_writes(2);
        page = [b'B'; PAGE_SIZE];
        match DoubleWrite::new(&mut disk2, 1).update(0, &mut page) {
            Ok(()) => writeln!(w, "update to B: ok")?,
            Err(err) => writeln!(w, "update to B, power off after 2 writes: {err:?}")?,
        }
        print_crash(w, &mut disk2, CrashMode::Tear)?;
        print_read(w, &mut disk2, 0)?;
        print_read(w, &mut disk2, 1)?;
        let mut scratch = [[0u8; PAGE_SIZE]; DoubleWrite::SCRATCH_PAGES];
        let r = DoubleWrite::new(&mut disk2, 1)
            .recover(&mut scratch)
            .map_err(|err| io::Error::other(format!("{err:?}")))?;
        writeln!(
            w,
            "recover: intact={} rolled_forward={} restored={} blank={}",
            r.intact, r.rolled_forward, r.restored, r.blank
        )?;
        print_read(w, &mut disk2, 1)?;
    }

    writeln!(
        w,
        "\n== 5. Crash at every write: 4 crash modes x 100 seeds per line =="
    )?;
    writeln!(w, "in-place update (1 write, 1 sync):")?;
    for crash_after in 0..2 {
        let o = in_place_outcomes(crash_after).map_err(io_err)?;
        writeln!(
            w,
            "  power off after {crash_after} writes: old={} new={} corrupt={}",
            o.old, o.new, o.corrupt
        )?;
    }
    writeln!(w, "double write (2 writes, 2 syncs), after recover:")?;
    for crash_after in 0..3 {
        let o = double_write_outcomes(crash_after).map_err(io_err)?;
        writeln!(
            w,
            "  power off after {crash_after} writes: old={} new={} corrupt={}",
            o.old, o.new, o.corrupt
        )?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::doublewrite::RecoverReport;
    use crate::file_storage::{FileStorage, TmpDir};

    #[test]
    fn run_prints_exactly_expected_output_txt() {
        let mut out = Vec::new();
        run(&mut out).unwrap();
        assert_eq!(
            String::from_utf8(out).unwrap(),
            include_str!("../../expected_output.txt")
        );
    }

    #[test]
    fn in_place_a_torn_overwrite_is_detected_but_the_page_is_gone() {
        let mut disk = SimDisk::new(DEMO_SEED);
        let mut page = [b'A'; PAGE_SIZE];
        update_in_place(&mut disk, 0, &mut page).unwrap();
        disk.power_off_after_writes(1);
        page = [b'B'; PAGE_SIZE];
        assert_eq!(
            update_in_place(&mut disk, 0, &mut page),
            Err(StorageError::PowerLoss)
        );
        disk.crash(CrashMode::Tear);
        assert_eq!(
            page::read_checked(&mut disk, 0, &mut page),
            Ok(Check::Corrupt)
        );
        // Neither version can be reconstructed: every sector is A or B, but
        // nothing on the disk says which sectors to trust.
        let map = sector_map(&page, 0);
        assert!(map.contains('A') && map.contains('B'));
    }

    #[test]
    fn the_same_code_runs_on_sim_disk_and_on_a_real_file() {
        let tmp = TmpDir::new("same_code");
        let mut file = FileStorage::open(tmp.0.join("dw.db")).unwrap();
        let mut disk = SimDisk::new(1);

        let mut scratch = [[0u8; PAGE_SIZE]; DoubleWrite::SCRATCH_PAGES];
        let stores: [&mut dyn Storage; 2] = [&mut file, &mut disk];
        for storage in stores {
            let mut dw = DoubleWrite::new(storage, 3);
            let mut page = [b'A'; PAGE_SIZE];
            dw.update(2, &mut page).unwrap();
            page = [b'B'; PAGE_SIZE];
            dw.update(0, &mut page).unwrap();
            let report = dw.recover(&mut scratch).unwrap();
            assert_eq!(
                report,
                RecoverReport {
                    intact: 2,
                    blank: 1,
                    ..Default::default()
                }
            );
            assert_eq!(dw.storage.size(), 6);
        }
        // Byte for byte the same image on both.
        let (mut a, mut b) = ([0u8; PAGE_SIZE], [0u8; PAGE_SIZE]);
        for p in 0..6 {
            file.read_page(p, &mut a).unwrap();
            disk.read_page(p, &mut b).unwrap();
            assert_eq!(a[..], b[..]);
        }
    }
}
