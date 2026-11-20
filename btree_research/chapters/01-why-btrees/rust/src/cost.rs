//! The cost model of this chapter (and of every database index):
//!
//! **count page reads, not comparisons.**
//!
//! Comparing two integers that are already in the CPU cache is about the
//! cheapest thing a computer does. Fetching a page that is not in memory is
//! a trip to the storage device, which is far more expensive (textbook; this
//! guide quotes no timings). So an index is judged by how many different
//! pages one operation has to touch.
//!
//! Everything here is a MODEL: we pretend the structure is laid out on
//! 4096-byte pages and count which pages an operation would touch. No real
//! I/O happens in this chapter (that starts in chapter 09).

/// Model page size in bytes (the default of SQLite/Turso; Postgres uses 8192).
pub const PAGE_SIZE: usize = 4096;

/// One key/value pair. Part I convention: both are u64.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Entry {
    pub key: u64,
    pub value: u64,
}

/// How many entries fit on one model page if the page holds nothing else.
/// Real pages also carry a header and per-entry bookkeeping (chapter 10).
pub const ENTRIES_PER_PAGE: usize = PAGE_SIZE / size_of::<Entry>(); // 256

const _: () = assert!(size_of::<Entry>() == 16 && ENTRIES_PER_PAGE == 256);

/// Counters for ONE lookup. Every `get_traced` in this chapter fills one in.
#[derive(Debug, Clone)]
pub struct Trace {
    /// Key comparisons performed (a three-way compare counts once).
    pub comparisons: u64,
    /// DISTINCT pages touched. A page that was already read during this
    /// lookup is assumed to still be in memory, so it is not counted again.
    pub page_reads: u64,
    /// The pages seen so far. A binary search over 2^64 entries makes at most
    /// 64 probes, so 64 slots are always enough for the sorted array.
    seen: [u64; 64],
}

impl Trace {
    pub const SEEN_CAPACITY: u64 = 64;

    pub fn new() -> Self {
        Self {
            comparisons: 0,
            page_reads: 0,
            seen: [0; 64],
        }
    }

    /// Record that the lookup looked at `page_id`.
    pub fn touch(&mut self, page_id: u64) {
        let count = self.page_reads as usize;
        if self.seen[..count].contains(&page_id) {
            return; // already in memory: free
        }
        self.seen[count] = page_id;
        self.page_reads += 1;
    }
}

impl Default for Trace {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn trace_counts_each_page_once() {
        let mut t = Trace::new();
        t.touch(7);
        t.touch(3);
        t.touch(7); // not adjacent to the first 7, still not counted again
        assert_eq!(t.page_reads, 2);
    }
}
