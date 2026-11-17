//! workload.rs: a seeded random page-access workload with an oracle.
//!
//! Used twice: by the model test below (several pool sizes, storage compared
//! with the oracle afterwards) and by part 3 of the demo (counters printed).
//! The Zig twin draws the same random numbers, so both languages perform the
//! same operations and print the same counters.

use crate::buffer_pool::BufferPool;
use crate::pager::PageId;
use crate::prng::SplitMix64;
use crate::storage::Error;

pub const PAGE_COUNT: usize = 64;
pub const OPS: usize = 5000;

/// What can go wrong: the pool failed, or it returned the wrong bytes.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WorkloadError {
    Pool(Error),
    WrongPageContent,
    Invalid(&'static str),
}

impl From<Error> for WorkloadError {
    fn from(e: Error) -> Self {
        WorkloadError::Pool(e)
    }
}

/// Run `OPS` random page accesses against `pool` and check every page
/// read against `expected`. 80% of accesses go to 8 hot pages; one access
/// in four modifies the page. Up to two pages are kept pinned across
/// operations to exercise the "skip pinned frames" path.
///
/// On an error (a failed fetch, wrong content, a broken invariant) every pin
/// taken here is released before returning, so the pool can still be used.
/// Zig does this with `errdefer`; here the loop lives in `run_ops` and this
/// wrapper releases the long-lived pins on both paths.
pub fn run(
    pool: &mut BufferPool,
    seed: u64,
    expected: &mut [u64; PAGE_COUNT],
) -> Result<(), WorkloadError> {
    let mut held: Vec<(PageId, bool)> = Vec::with_capacity(2);
    let result = run_ops(pool, seed, expected, &mut held);
    for (id, dirty) in held {
        pool.unpin(id, dirty);
    }
    result
}

/// The loop of `run`. `held` are the long-lived pins; whatever is in it when
/// this returns, with or without an error, is still pinned.
fn run_ops(
    pool: &mut BufferPool,
    seed: u64,
    expected: &mut [u64; PAGE_COUNT],
    held: &mut Vec<(PageId, bool)>,
) -> Result<(), WorkloadError> {
    let mut rng = SplitMix64::new(seed);
    // Always leave at least one frame unpinned, or fetches would fail.
    let max_held = 2.min(pool.frame_count() - 1);

    for _ in 0..OPS {
        let id = if rng.chance(4, 5) {
            rng.below(8)
        } else {
            rng.below(PAGE_COUNT as u64)
        } as PageId;
        let write = rng.chance(1, 4);
        let hold = rng.chance(1, 16);

        if !held.is_empty() && held.len() == max_held {
            // Release the oldest long-lived pin to make room for a new one.
            let (old_id, old_dirty) = held.remove(0);
            pool.unpin(old_id, old_dirty);
        }

        let page = pool.fetch_page(id)?;
        let want = &mut expected[id as usize];
        if u64::from_le_bytes(page[8..16].try_into().expect("8 bytes")) != *want {
            // This pin is not in `held`: release it here, before the error.
            pool.unpin(id, false);
            return Err(WorkloadError::WrongPageContent);
        }
        if write {
            *want += 1;
            page[8..16].copy_from_slice(&want.to_le_bytes());
        }
        if hold && held.len() < max_held {
            held.push((id, write));
        } else {
            pool.unpin(id, write);
        }
        pool.validate().map_err(WorkloadError::Invalid)?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::pager::{PAGE_SIZE, Pager};
    use crate::storage::MemStorage;

    #[test]
    fn seeded_model_test_against_an_oracle_several_pool_sizes() {
        for frame_count in [1usize, 2, 4, 8, 16, 64, 100] {
            let mem = MemStorage::new();
            let mut pager = Pager::new(Box::new(mem.clone())).unwrap();
            for _ in 0..PAGE_COUNT {
                pager.allocate_page().unwrap();
            }
            pager.stats = Default::default();
            let mut pool = BufferPool::new(pager, frame_count);

            let mut expected = [0u64; PAGE_COUNT];
            run(&mut pool, 0xB7EE + frame_count as u64, &mut expected).unwrap();
            assert_eq!(pool.stats.hits + pool.stats.misses, OPS as u64);
            assert_eq!(pool.stats.misses, pool.pager().stats.reads);
            // A page is only ever evicted to load another one.
            assert!(pool.stats.evictions <= pool.stats.misses);
            if frame_count >= PAGE_COUNT {
                assert_eq!(pool.stats.evictions, 0);
            }
            // Rust's pool does not check for leaked pins when dropped.
            assert_eq!(pool.pinned_frames(), 0);

            // After a flush the storage itself must agree with the oracle.
            pool.flush_all().unwrap();
            let bytes = mem.bytes();
            for (id, want) in expected.iter().enumerate() {
                let at = id * PAGE_SIZE + 8;
                assert_eq!(
                    u64::from_le_bytes(bytes[at..at + 8].try_into().unwrap()),
                    *want
                );
            }
        }
    }

    #[derive(Clone, Copy)]
    enum Fault {
        Write(u64),
        Read(u64),
        Content,
    }

    /// Run the workload on a 4-frame pool with one injected fault and check
    /// that the error comes back with no pin left and the pool still valid.
    fn run_with_fault(fault: Fault, want: WorkloadError) {
        let mem = MemStorage::new();
        let mut pager = Pager::new(Box::new(mem.clone())).unwrap();
        for _ in 0..PAGE_COUNT {
            pager.allocate_page().unwrap();
        }
        let mut pool = BufferPool::new(pager, 4);

        let mut expected = [0u64; PAGE_COUNT];
        match fault {
            Fault::Write(after) => mem.set_writes_before_failure(Some(after)),
            Fault::Read(after) => mem.set_reads_before_failure(Some(after)),
            // Page 0 is hot, so it is read early: make the oracle disagree.
            Fault::Content => expected[0] = 99,
        }
        assert_eq!(run(&mut pool, 2024, &mut expected), Err(want));
        assert_eq!(pool.pinned_frames(), 0);
        pool.validate().unwrap();
    }

    #[test]
    fn an_error_while_pins_are_held_is_returned_and_the_pins_are_released() {
        let io = WorkloadError::Pool(Error::StorageFailure);
        // 200 write-backs / 300 reads into the run, long-lived pins are held.
        run_with_fault(Fault::Write(200), io);
        run_with_fault(Fault::Read(300), io);
        run_with_fault(Fault::Content, WorkloadError::WrongPageContent);
        // Every failure point in the first part of the run, both kinds.
        for n in 0..150 {
            run_with_fault(Fault::Write(n), io);
            run_with_fault(Fault::Read(n), io);
        }
    }
}
