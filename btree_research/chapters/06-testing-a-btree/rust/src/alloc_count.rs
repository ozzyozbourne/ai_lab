//! A counting `#[global_allocator]`: the Rust half of "an allocator wrapper
//! that counts".
//!
//! Zig passes an allocator to every function, so a test wraps exactly the
//! allocator it hands to the tree (fault_alloc.zig). Rust's collections ask
//! one process-wide allocator instead; the only place to count is there.
//! `GlobalAlloc` is an `unsafe trait` (the compiler cannot check that `alloc`
//! returns valid, properly aligned memory), so this file is the guide's ONE
//! declared exception to "safe code only" in Part I. The unsafe code is four
//! one-line forwards to the system allocator; the counting itself is safe.
//!
//! The counters are per THREAD. `cargo test` runs tests on several threads
//! at once, and a process-wide counter would mix their allocations; a
//! thread-local counter sees only what the current test did.
//!
//! What it cannot do is FAIL an allocation usefully: `Vec::push` aborts the
//! process when the allocator returns null. Failure injection stays where
//! chapter 04 put it, in the slab's node budget (base_pool.rs: `budget`,
//! `fail_after`).
#![allow(unsafe_code)]

use std::alloc::{GlobalAlloc, Layout, System};
use std::cell::Cell;

/// What the current thread has asked of the allocator so far.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct AllocStats {
    /// Calls of `alloc` (a `realloc` that moves or grows counts as neither).
    pub allocations: u64,
    pub frees: u64,
    /// Calls of `realloc`: a `Vec` growing in place or moving.
    pub reallocations: u64,
    /// Bytes currently held. Signed, like `live()`: a block allocated on
    /// one thread and freed on another makes the per-thread balance drift,
    /// possibly below zero. Single-threaded test bodies never see that.
    pub live_bytes: i64,
}

impl AllocStats {
    /// Allocations not yet freed. Equal before and after a piece of code
    /// means that code leaked nothing.
    pub fn live(&self) -> i64 {
        self.allocations as i64 - self.frees as i64
    }
}

thread_local! {
    // `const` initialisation and no destructor: reading this from inside the
    // allocator can neither allocate nor run after the value was destroyed.
    static STATS: Cell<AllocStats> = const {
        Cell::new(AllocStats { allocations: 0, frees: 0, reallocations: 0, live_bytes: 0 })
    };
}

/// The current thread's counters.
pub fn stats() -> AllocStats {
    STATS.with(Cell::get)
}

fn update(change: impl FnOnce(&mut AllocStats)) {
    // `try_with`: during thread teardown the slot may be gone; then the
    // event is simply not counted.
    let _ = STATS.try_with(|cell| {
        let mut stats = cell.get();
        change(&mut stats);
        cell.set(stats);
    });
}

/// Forwards every request to the system allocator and counts it.
pub struct CountingAlloc;

// SAFETY: every method forwards its arguments unchanged to `System`, which
// upholds the `GlobalAlloc` contract; the bookkeeping around the calls
// touches only a thread-local `Cell` and never allocates or unwinds.
unsafe impl GlobalAlloc for CountingAlloc {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        // SAFETY: the caller guarantees `layout` has non-zero size.
        let ptr = unsafe { System.alloc(layout) };
        if !ptr.is_null() {
            update(|s| {
                s.allocations += 1;
                s.live_bytes += layout.size() as i64;
            });
        }
        ptr
    }

    unsafe fn dealloc(&self, ptr: *mut u8, layout: Layout) {
        // SAFETY: the caller guarantees `ptr` came from this allocator with
        // this `layout`, and this allocator only hands out `System` blocks.
        unsafe { System.dealloc(ptr, layout) };
        update(|s| {
            s.frees += 1;
            s.live_bytes -= layout.size() as i64;
        });
    }

    unsafe fn realloc(&self, ptr: *mut u8, layout: Layout, new_size: usize) -> *mut u8 {
        // SAFETY: same guarantees as `dealloc`, plus a non-zero `new_size`.
        let new_ptr = unsafe { System.realloc(ptr, layout, new_size) };
        if !new_ptr.is_null() {
            update(|s| {
                s.reallocations += 1;
                s.live_bytes += new_size as i64 - layout.size() as i64;
            });
        }
        new_ptr
    }

    // `alloc_zeroed` is not overridden: the default calls `alloc` above and
    // zeroes the block, so it is counted once.
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn counts_allocations_frees_and_bytes_of_this_thread() {
        let before = stats();
        let xs: Vec<u64> = Vec::with_capacity(10);
        let boxed = Box::new([0u8; 32]);
        let during = stats();
        assert_eq!(during.allocations - before.allocations, 2);
        assert_eq!(during.live() - before.live(), 2);
        assert_eq!(during.live_bytes - before.live_bytes, 80 + 32);
        drop(xs);
        drop(boxed);
        let after = stats();
        assert_eq!(after.live(), before.live()); // nothing leaked
        assert_eq!(after.live_bytes, before.live_bytes);
    }

    #[test]
    fn a_growing_vec_shows_up_as_reallocations() {
        let before = stats();
        let mut xs: Vec<u64> = Vec::new(); // no allocation yet
        assert_eq!(stats().allocations, before.allocations);
        for i in 0..100 {
            xs.push(i);
        }
        let after = stats();
        assert_eq!(after.allocations - before.allocations, 1);
        assert!(after.reallocations > before.reallocations);
        assert_eq!(
            after.live_bytes - before.live_bytes,
            8 * xs.capacity() as i64
        );
    }

    #[test]
    fn a_leak_is_visible_as_a_live_allocation() {
        let before = stats();
        let leaked: &'static mut u64 = Box::leak(Box::new(7));
        assert_eq!(stats().live() - before.live(), 1);
        // Taking it back needs `Box::from_raw`, which is unsafe: these 8
        // bytes stay leaked on purpose.
        *leaked += 1;
    }

    #[test]
    fn another_thread_has_its_own_counters() {
        let before = stats();
        std::thread::spawn(|| {
            let v = vec![1u8; 4096];
            assert!(stats().live_bytes >= v.len() as i64);
        })
        .join()
        .unwrap();
        // The spawn itself allocates a little on this thread; the 4096-byte
        // block of the other thread is not among it.
        assert!(stats().live_bytes - before.live_bytes < 4096);
    }
}
