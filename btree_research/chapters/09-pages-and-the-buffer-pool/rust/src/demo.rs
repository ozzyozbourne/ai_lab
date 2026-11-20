//! demo.rs: the fixed, deterministic scenario printed by `cargo run`.
//!
//! Part 1  a pager over a real file: allocate, write, sync, reopen, read.
//! Part 2  a 4-frame buffer pool over that file, driven by a fixed trace that
//!         shows a hit, a second chance, a skipped pinned frame, a dirty
//!         write-back and the all-frames-pinned error. The visualization
//!         replays exactly this trace and checks its final state.
//! Part 3  the same seeded workload against pools of 4, 8, 16 and 32 frames
//!         on an in-memory storage: only the counters change.

use std::error::Error as StdError;
use std::io::Write;
use std::path::Path;

use crate::buffer_pool::BufferPool;
use crate::pager::{INVALID_PAGE_ID, PAGE_SIZE, Page, PageId, Pager};
use crate::storage::{FileStorage, MemStorage};
use crate::workload;

pub const DB_NAME: &str = "ch09_demo.db";

type DemoResult = Result<(), Box<dyn StdError>>;

/// Demo page layout: bytes 0..4 = the page's own id, bytes 8..16 = a version
/// counter that every "edit" increments. Little-endian, like every on-disk
/// integer in this guide.
fn stamp(page: &mut Page, id: PageId, version: u64) {
    page[0..4].copy_from_slice(&id.to_le_bytes());
    page[8..16].copy_from_slice(&version.to_le_bytes());
}
fn id_of(page: &Page) -> u32 {
    u32::from_le_bytes(page[0..4].try_into().expect("4 bytes"))
}
fn version_of(page: &Page) -> u64 {
    u64::from_le_bytes(page[8..16].try_into().expect("8 bytes"))
}

pub fn run(w: &mut dyn Write, dir: &Path) -> DemoResult {
    let path = dir.join(DB_NAME);
    let result = run_parts(w, &path);
    // Remove the demo file on every path out of here, errors included.
    let _ = std::fs::remove_file(&path);
    result
}

fn run_parts(w: &mut dyn Write, path: &Path) -> DemoResult {
    writeln!(w, "Chapter 09: pages and the buffer pool")?;
    part1(w, path)?;
    part2(w, path)?;
    part3(w)
}

fn part1(w: &mut dyn Write, path: &Path) -> DemoResult {
    writeln!(w, "\n== Part 1: a file is an array of pages ==")?;
    {
        let mut pager = Pager::new(Box::new(FileStorage::create(path)?))?;
        writeln!(w, "created {}: {} pages", DB_NAME, pager.page_count())?;

        let mut page = [0u8; PAGE_SIZE];
        for _ in 0..8 {
            let id = pager.allocate_page()?;
            stamp(&mut page, id, 0);
            pager.write_page(id, &page)?;
        }
        pager.sync()?;
        let size = std::fs::metadata(path)?.len();
        writeln!(
            w,
            "allocated 8 pages: file size = {size} bytes (8 * {PAGE_SIZE})"
        )?;
        print_pager_stats(w, &pager)?;
    }
    let mut pager = Pager::new(Box::new(FileStorage::open(path)?))?;
    writeln!(w, "reopened: {} pages", pager.page_count())?;
    let mut page = [0u8; PAGE_SIZE];
    pager.read_page(5, &mut page)?;
    writeln!(
        w,
        "page 5 is at byte offset {}; its id field says {}, version {}",
        Pager::offset_of(5),
        id_of(&page),
        version_of(&page)
    )?;
    let err = pager
        .read_page(8, &mut page)
        .expect_err("page 8 must not exist");
    writeln!(w, "page 8 does not exist: {err}")?;
    Ok(())
}

#[derive(Debug, Clone, Copy)]
enum Op {
    /// fetch_page and keep the pin
    Fetch(PageId),
    /// unpin, page not modified
    Unpin(PageId),
    /// increment the page's version, then unpin with dirty = true
    Edit(PageId),
}
use Op::{Edit, Fetch, Unpin};

/// The fixed trace. Kept in step with viz/index.html (TRACE).
#[rustfmt::skip]
const TRACE: [Op; 29] = [
    Fetch(0), Unpin(0), // fill the four frames
    Fetch(1), Edit(1), // page 1 becomes dirty
    Fetch(2), Unpin(2),
    Fetch(3), Unpin(3),
    Fetch(1), Unpin(1), // hit
    Fetch(4), Unpin(4), // first eviction: full sweep
    Fetch(1), Unpin(1), // hit: sets the referenced bit again
    Fetch(5), Unpin(5), // page 1 gets its second chance
    Fetch(3), // stays pinned
    Fetch(6), Edit(6), // skips pinned page 3, writes back page 1
    Fetch(4), Fetch(5), Fetch(6), // now all four are pinned
    Fetch(7), // error
    Unpin(3), Unpin(4), Unpin(5), Unpin(6),
    Fetch(7), Unpin(7),
];

const FRAME_COUNT: usize = 4;

fn part2(w: &mut dyn Write, path: &Path) -> DemoResult {
    writeln!(
        w,
        "\n== Part 2: a {FRAME_COUNT}-frame buffer pool with CLOCK eviction =="
    )?;
    writeln!(
        w,
        "frame cell = page, pin count, R = referenced, D = dirty; hand = next frame the clock looks at\n"
    )?;
    {
        let pager = Pager::new(Box::new(FileStorage::open(path)?))?;
        let mut pool = BufferPool::new(pager, FRAME_COUNT);

        writeln!(
            w,
            " #  op       outcome                               f0       f1       f2       f3       hand"
        )?;
        for (i, op) in TRACE.iter().enumerate() {
            let before = pool.stats;
            let old_frames = pool.frames().to_vec();

            let (op_text, outcome) = match *op {
                Fetch(id) => {
                    let outcome = match pool.fetch_page(id) {
                        Ok(_) => {
                            let f = pool.frame_of(id).expect("just fetched");
                            if pool.stats.hits > before.hits {
                                format!("hit in f{f}")
                            } else if pool.stats.writebacks > before.writebacks {
                                format!(
                                    "miss: write back + evict page {} (f{f})",
                                    old_frames[f].page_id
                                )
                            } else if pool.stats.evictions > before.evictions {
                                format!("miss: evict page {} (f{f})", old_frames[f].page_id)
                            } else {
                                format!("miss: load into empty f{f}")
                            }
                        }
                        Err(err) => err.to_string(),
                    };
                    (format!("fetch {id}"), outcome)
                }
                Unpin(id) => {
                    pool.unpin(id, false);
                    (
                        format!("unpin {id}"),
                        "released, page unchanged".to_string(),
                    )
                }
                Edit(id) => {
                    // The trace pinned this page with an earlier fetch; borrow
                    // it again through the pin.
                    let page = pool.page_mut(id);
                    let version = version_of(page) + 1;
                    stamp(page, id, version);
                    pool.unpin(id, true);
                    (
                        format!("edit {id}"),
                        format!("version -> {version}, released dirty"),
                    )
                }
            };
            pool.validate()?;
            write!(w, "{:>2}  {:<8} {:<37}", i + 1, op_text, outcome)?;
            print_frames(w, &pool)?;
        }

        writeln!(
            w,
            "\nfinal state (the visualization's self-test checks these lines):"
        )?;
        for (f, frame) in pool.frames().iter().enumerate() {
            writeln!(
                w,
                "  frame {}: page={} pin={} referenced={} dirty={}",
                f, frame.page_id, frame.pin_count, frame.referenced as u8, frame.dirty as u8
            )?;
        }
        writeln!(w, "  hand={}", pool.hand())?;
        let s = pool.stats;
        writeln!(
            w,
            "  pool:  hits={} misses={} evictions={} writebacks={}",
            s.hits, s.misses, s.evictions, s.writebacks
        )?;
        print_pager_stats(w, pool.pager())?;

        pool.flush_all()?;
        writeln!(w, "after flushAll:")?;
        print_pager_stats(w, pool.pager())?;
    }

    // Reopen without a pool: the edits must be in the file.
    let mut pager = Pager::new(Box::new(FileStorage::open(path)?))?;
    let mut page = [0u8; PAGE_SIZE];
    write!(w, "reopened; versions on disk:")?;
    for id in 0..pager.page_count() {
        pager.read_page(id, &mut page)?;
        write!(w, " {}", version_of(&page))?;
    }
    writeln!(w)?;
    Ok(())
}

fn part3(w: &mut dyn Write) -> DemoResult {
    writeln!(
        w,
        "\n== Part 3: {} page accesses over {} pages (80% to 8 hot pages), in-memory storage ==",
        workload::OPS,
        workload::PAGE_COUNT
    )?;
    writeln!(
        w,
        "frames   hits  misses  evictions  writebacks  file reads  file writes"
    )?;
    for frames in [4usize, 8, 16, 32] {
        let mem = MemStorage::new();
        let mut pager = Pager::new(Box::new(mem.clone()))?;
        for _ in 0..workload::PAGE_COUNT {
            pager.allocate_page()?;
        }
        pager.stats = Default::default();
        let mut pool = BufferPool::new(pager, frames);

        let mut expected = [0u64; workload::PAGE_COUNT];
        workload::run(&mut pool, 2024, &mut expected).map_err(|e| format!("{e:?}"))?;
        pool.flush_all()?;
        // Verify the storage against the oracle, page by page.
        let bytes = mem.bytes();
        for (id, want) in expected.iter().enumerate() {
            let at = id * PAGE_SIZE + 8;
            if u64::from_le_bytes(bytes[at..at + 8].try_into().expect("8 bytes")) != *want {
                return Err("wrong page content".into());
            }
        }
        let (s, p) = (pool.stats, pool.pager().stats);
        writeln!(
            w,
            "{:>6}  {:>5}  {:>6}  {:>9}  {:>10}  {:>10}  {:>11}",
            frames, s.hits, s.misses, s.evictions, s.writebacks, p.reads, p.writes
        )?;
    }
    writeln!(
        w,
        "every run ended with the same page contents as the oracle"
    )?;
    Ok(())
}

fn print_frames(w: &mut dyn Write, pool: &BufferPool) -> DemoResult {
    for frame in pool.frames() {
        let cell = if frame.page_id == INVALID_PAGE_ID {
            "-".to_string()
        } else {
            format!(
                "{} p{} {}{}",
                frame.page_id,
                frame.pin_count,
                if frame.referenced { 'R' } else { '-' },
                if frame.dirty { 'D' } else { '-' }
            )
        };
        write!(w, " {cell:<8}")?;
    }
    writeln!(w, " {}", pool.hand())?;
    Ok(())
}

fn print_pager_stats(w: &mut dyn Write, pager: &Pager) -> DemoResult {
    let s = pager.stats;
    writeln!(
        w,
        "  pager: reads={} writes={} allocations={} syncs={}",
        s.reads, s.writes, s.allocations, s.syncs
    )?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A writer that accepts `left` bytes and then fails, like Zig's fixed
    /// writer with a full buffer.
    struct Limited {
        left: usize,
    }

    impl Write for Limited {
        fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
            if bytes.len() > self.left {
                return Err(std::io::Error::other("output is full"));
            }
            self.left -= bytes.len();
            Ok(bytes.len())
        }
        fn flush(&mut self) -> std::io::Result<()> {
            Ok(())
        }
    }

    #[test]
    fn a_failing_output_writer_is_reported_as_an_error_and_leaves_no_file_behind() {
        let tmp = crate::TempDir::new("demo_failing_writer");
        let full = include_str!("../../expected_output.txt").len();
        // Sweep the limit so that the failure lands in every part of the
        // demo, including the steps of part 2 that hold up to four pins.
        let mut failures = 0;
        for limit in (0..=4200).step_by(59) {
            let result = run(&mut Limited { left: limit }, &tmp.0);
            if limit >= full {
                assert!(result.is_ok());
            } else {
                assert!(result.is_err(), "limit {limit}");
                failures += 1;
            }
            assert!(!tmp.0.join(DB_NAME).exists());
        }
        assert!(failures > 60);
    }
}
