//! The cost model of this chapter (and of every database index):
//!
//!     count PAGE READS, not comparisons.
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
const std = @import("std");

/// Model page size in bytes (the default of SQLite/Turso; Postgres uses 8192).
pub const page_size: usize = 4096;

/// One key/value pair. Part I convention: both are u64.
pub const Entry = struct { key: u64, value: u64 };

/// How many entries fit on one model page if the page holds nothing else.
/// Real pages also carry a header and per-entry bookkeeping (chapter 10).
pub const entries_per_page: usize = page_size / @sizeOf(Entry); // 256

comptime {
    std.debug.assert(@sizeOf(Entry) == 16);
    std.debug.assert(entries_per_page == 256);
}

/// Counters for ONE lookup. Every `getTraced` in this chapter fills one in.
pub const Trace = struct {
    /// Key comparisons performed (a three-way compare counts once).
    comparisons: u64 = 0,
    /// DISTINCT pages touched. A page that was already read during this
    /// lookup is assumed to still be in memory, so it is not counted again.
    page_reads: u64 = 0,
    /// The pages seen so far. A binary search over 2^64 entries makes at most
    /// 64 probes, so 64 slots are always enough for the sorted array.
    seen: [64]u64 = undefined,

    /// Record that the lookup looked at `page_id`.
    pub fn touch(self: *Trace, page_id: u64) void {
        for (self.seen[0..self.page_reads]) |p| {
            if (p == page_id) return; // already in memory: free
        }
        self.seen[self.page_reads] = page_id;
        self.page_reads += 1;
    }
};

test "Trace counts each page once" {
    var t: Trace = .{};
    t.touch(7);
    t.touch(3);
    t.touch(7); // not adjacent to the first 7, still not counted again
    try std.testing.expectEqual(2, t.page_reads);
}
