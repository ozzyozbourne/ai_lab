//! A cache-line accounting model (twin of zig/src/trace.zig).
//!
//! Chapter 01 counted page reads instead of comparisons. This chapter zooms in
//! one level: inside a page (or inside any in-memory array) the unit of cost
//! is the 64-byte cache line. Every search algorithm in this chapter takes a
//! `Tracer` and reports every memory read that depends on the needle. Two
//! tracers exist:
//!
//!   * `NoTrace`: every method is empty; after monomorphisation and inlining
//!     nothing is left of the calls. This is the code you would ship.
//!   * `Trace`: counts comparisons and remembers which cache lines were read.
//!
//! Because the same generic function runs with both, the counted algorithm
//! cannot drift from the fast one.
//!
//! What the model counts. A lookup may read two arrays: the KEY array
//! (`cmp`, `cmp_block`) and a SIDE array of 4-byte entries (`side`): the
//! `rank` array of the layouts in layout.rs, or the child column of a
//! struct-of-arrays node. `lines_read()` is the sum of the distinct lines of
//! both, so a lookup cannot hide a read in an array the model does not see.
//!
//! What the model assumes. Each array starts on a cache-line boundary. That
//! is true for every key array the fixed scenario searches with
//! `Layout::KEYS` (they are `Vec<Line>`, see layout.rs). It is NOT guaranteed
//! for the two node types in node.rs, whose `Vec`s align to 8 bytes: their
//! counts describe a node that starts on a line boundary, and a node that
//! does not can touch one line more. A side read is one 4-byte entry, which
//! lies inside one line wherever its array starts, and the model takes the
//! side array to share no line with the key array.
//!
//! The model knows nothing about TLBs, the hardware prefetcher or cache
//! sizes. It produces counts, never timings.

/// Bytes per cache line on every mainstream x86-64 and most AArch64 CPUs.
pub const LINE_BYTES: usize = 64;
/// u64 keys that fit in one line; also the chunk size of the "vector" scan.
pub const LANES: usize = LINE_BYTES / size_of::<u64>();
/// Largest array the model can describe: 2048 lines = 128 KiB.
pub const MAX_LINES: usize = 2048;
/// How many probe positions a trace remembers (enough for any binary search).
pub const MAX_PROBES: usize = 16;
/// Prefetch hints that may be issued between two comparisons.
pub const MAX_PENDING: usize = 4;

/// Where the key of element `i` lives: byte `i * stride + offset` of the array.
/// A plain `[u64]` has stride 8. An array of 16-byte `{key, child}` structs
/// has stride 16: only four keys share a line.
#[derive(Debug, Clone, Copy)]
pub struct Layout {
    pub stride: usize,
    pub offset: usize,
}

impl Layout {
    /// A dense array of u64 keys.
    pub const KEYS: Layout = Layout {
        stride: size_of::<u64>(),
        offset: 0,
    };
    /// A dense array of u32 ranks or child ids: sixteen per line.
    pub const SIDE: Layout = Layout {
        stride: size_of::<u32>(),
        offset: 0,
    };

    pub fn line_of(self, index: usize) -> usize {
        (index * self.stride + self.offset) / LINE_BYTES
    }
}

/// A set of cache-line numbers as a fixed bitmap. No allocation: a trace is
/// created and thrown away for every single lookup.
#[derive(Debug, Clone)]
pub struct LineSet {
    words: [u64; MAX_LINES / 64],
    pub count: u32,
}

impl LineSet {
    pub fn new() -> Self {
        Self {
            words: [0; MAX_LINES / 64],
            count: 0,
        }
    }

    /// Adds `line`; returns true when it was not in the set before.
    pub fn insert(&mut self, line: usize) -> bool {
        assert!(
            line < MAX_LINES,
            "trace: the array is larger than the model's MAX_LINES"
        );
        let bit = 1u64 << (line % 64);
        let fresh = self.words[line / 64] & bit == 0;
        self.words[line / 64] |= bit;
        self.count += u32::from(fresh);
        fresh
    }

    pub fn contains(&self, line: usize) -> bool {
        line < MAX_LINES && self.words[line / 64] & (1u64 << (line % 64)) != 0
    }
}

/// What a search reports while it runs. Zig passes `tracer: anytype` and
/// resolves the calls by duck typing at compile time; Rust names the contract.
pub trait Tracer {
    /// One scalar comparison against key `index`.
    fn cmp(&mut self, index: usize);
    /// One chunk ("vector") comparison against `count` keys from `index`.
    fn cmp_block(&mut self, index: usize, count: usize);
    /// A prefetch hint for the line holding key `index`.
    fn prefetch(&mut self, index: usize);
    /// One read of entry `index` of the side array (a rank or a child id).
    fn side(&mut self, index: usize);
}

#[derive(Debug, Clone)]
pub struct Trace {
    /// Where the keys are (the array `cmp` and `cmp_block` index).
    pub layout: Layout,
    /// Where the side entries are (the array `side` indexes).
    pub side_layout: Layout,
    /// Key comparisons. A chunk compare of 8 lanes counts as 8.
    pub comparisons: u32,
    /// Compare instructions: 1 per scalar compare, 1 per 8-lane compare.
    pub steps: u32,
    /// Prefetch hints issued.
    pub prefetches: u32,
    /// Distinct lines of the key array that were read.
    pub read: LineSet,
    /// Distinct lines of the side array that were read.
    pub side_read: LineSet,
    /// Key lines named by a hint that has had lead time: at least one
    /// comparison was made between the hint and now.
    pub hinted: LineSet,
    /// Key lines hinted since the last comparison. A hint issued immediately
    /// before the read it names has bought nothing: the load still has to
    /// wait for the whole miss. So these do not cover the next read; they
    /// move to `hinted` once that comparison is done.
    pending: [usize; MAX_PENDING],
    pending_len: usize,
    /// Lines (of either array) read for the first time without a hint that
    /// had lead time. On a cold cache each of these is a miss the CPU must
    /// wait for before it can even compute the next address. Hinted lines
    /// are already on their way.
    pub uncovered: u32,
    /// The first `MAX_PROBES` element indexes compared, for the hand example.
    probes: [u32; MAX_PROBES],
    probe_len: usize,
}

impl Trace {
    pub fn new(layout: Layout) -> Self {
        Self {
            layout,
            side_layout: Layout::SIDE,
            comparisons: 0,
            steps: 0,
            prefetches: 0,
            read: LineSet::new(),
            side_read: LineSet::new(),
            hinted: LineSet::new(),
            pending: [0; MAX_PENDING],
            pending_len: 0,
            uncovered: 0,
            probes: [0; MAX_PROBES],
            probe_len: 0,
        }
    }

    /// Distinct key-array lines read.
    pub fn key_lines(&self) -> u32 {
        self.read.count
    }

    /// Distinct side-array lines read.
    pub fn side_lines(&self) -> u32 {
        self.side_read.count
    }

    /// Every distinct line the lookup read, in both arrays.
    pub fn lines_read(&self) -> u32 {
        self.read.count + self.side_read.count
    }

    pub fn probes(&self) -> &[u32] {
        &self.probes[..self.probe_len]
    }

    fn read_line(&mut self, line: usize) {
        if self.read.insert(line) && !self.hinted.contains(line) {
            self.uncovered += 1;
        }
    }

    /// The comparison that just ran is the lead time of every pending hint.
    fn settle_hints(&mut self) {
        for i in 0..self.pending_len {
            self.hinted.insert(self.pending[i]);
        }
        self.pending_len = 0;
    }

    fn note(&mut self, index: usize) {
        if self.probe_len < MAX_PROBES {
            self.probes[self.probe_len] = index as u32;
            self.probe_len += 1;
        }
    }
}

impl Tracer for Trace {
    fn cmp(&mut self, index: usize) {
        self.comparisons += 1;
        self.steps += 1;
        self.note(index);
        self.read_line(self.layout.line_of(index));
        self.settle_hints();
    }

    fn cmp_block(&mut self, index: usize, count: usize) {
        self.comparisons += count as u32;
        self.steps += 1;
        self.note(index);
        for line in self.layout.line_of(index)..=self.layout.line_of(index + count - 1) {
            self.read_line(line);
        }
        self.settle_hints();
    }

    fn prefetch(&mut self, index: usize) {
        self.prefetches += 1;
        // Indexing would panic anyway; this names the limit that was exceeded.
        assert!(
            self.pending_len < MAX_PENDING,
            "trace: more than MAX_PENDING hints between two comparisons"
        );
        self.pending[self.pending_len] = self.layout.line_of(index);
        self.pending_len += 1;
    }

    /// Nothing in this chapter prefetches the side array, so a first read of
    /// one of its lines is always uncovered.
    fn side(&mut self, index: usize) {
        if self.side_read.insert(self.side_layout.line_of(index)) {
            self.uncovered += 1;
        }
    }
}

/// The tracer that does nothing. A search instantiated with `NoTrace`
/// compiles to exactly the untraced loop.
#[derive(Debug, Clone, Copy)]
pub struct NoTrace;

impl Tracer for NoTrace {
    #[inline(always)]
    fn cmp(&mut self, _index: usize) {}
    #[inline(always)]
    fn cmp_block(&mut self, _index: usize, _count: usize) {}
    #[inline(always)]
    fn prefetch(&mut self, _index: usize) {}
    #[inline(always)]
    fn side(&mut self, _index: usize) {}
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn layout_eight_u64_keys_per_line_four_16_byte_entries_per_line() {
        assert_eq!(Layout::KEYS.line_of(7), 0);
        assert_eq!(Layout::KEYS.line_of(8), 1);
        let aos = Layout {
            stride: 16,
            offset: 0,
        };
        assert_eq!(aos.line_of(3), 0);
        assert_eq!(aos.line_of(4), 1);
        assert_eq!(Layout::SIDE.line_of(15), 0);
        assert_eq!(Layout::SIDE.line_of(16), 1);
    }

    #[test]
    fn trace_distinct_lines_vector_steps_and_prefetch_coverage() {
        let mut t = Trace::new(Layout::KEYS);
        t.cmp(0);
        t.cmp(7); // same line as index 0
        t.cmp(8); // second line
        assert_eq!(t.comparisons, 3);
        assert_eq!(t.lines_read(), 2);
        assert_eq!(t.uncovered, 2);

        t.prefetch(100); // line 12, hinted one comparison before it is read
        t.cmp(50); // line 6: the lead time of the hint
        t.cmp(100);
        assert_eq!(t.lines_read(), 4);
        assert_eq!(t.uncovered, 3); // line 6 was a surprise, line 12 was not

        t.cmp_block(16, 8); // one instruction, eight lanes, one line
        assert_eq!(t.comparisons, 13);
        assert_eq!(t.steps, 6);
        assert_eq!(t.lines_read(), 5);
        assert_eq!(t.probes(), &[0, 7, 8, 50, 100, 16]);
    }

    // Regression (review round 1, G4): a hint used to "cover" a read that came
    // straight after it, so a 15-key search reported no surprising line at all.
    #[test]
    fn trace_a_hint_with_no_comparison_in_between_does_not_cover_the_read() {
        let mut t = Trace::new(Layout::KEYS);
        t.prefetch(100);
        t.cmp(100); // same step as the hint: the miss is not hidden
        assert_eq!(t.uncovered, 1);
        t.prefetch(200);
        t.prefetch(300);
        t.cmp(100); // lead time for both hints
        t.cmp(200);
        t.cmp(300);
        assert_eq!(t.uncovered, 1);
        assert_eq!(t.prefetches, 3);
        assert_eq!(t.key_lines(), 3);
    }

    // Regression (review round 2, G-R2-9): the Zig twin guarded `pending` with
    // an assert only. The buffer must take exactly `MAX_PENDING` hints between
    // two comparisons, and be empty again after the comparison.
    #[test]
    fn trace_max_pending_hints_between_two_comparisons_fit_and_all_get_lead_time() {
        let mut t = Trace::new(Layout::KEYS);
        for round in 0..3 {
            for i in 0..MAX_PENDING {
                t.prefetch(8 * (1 + round * MAX_PENDING + i));
            }
            assert_eq!(t.pending_len, MAX_PENDING);
            t.cmp(0); // lead time for all of them; the buffer is free again
            assert_eq!(t.pending_len, 0);
        }
        for i in 0..3 * MAX_PENDING {
            t.cmp(8 * (1 + i)); // every one of these lines was hinted in time
        }
        assert_eq!(t.uncovered, 1); // only line 0
        assert_eq!(t.prefetches as usize, 3 * MAX_PENDING);
        assert_eq!(t.key_lines() as usize, 3 * MAX_PENDING + 1);
    }

    #[test]
    #[should_panic(expected = "more than MAX_PENDING hints")]
    fn trace_one_hint_too_many_between_two_comparisons_panics() {
        let mut t = Trace::new(Layout::KEYS);
        for i in 0..=MAX_PENDING {
            t.prefetch(8 * i);
        }
    }

    // Regression (review round 1, G1): reads of the rank / child array were
    // invisible to the model.
    #[test]
    fn trace_side_array_reads_are_lines_too_counted_apart_from_key_lines() {
        let mut t = Trace::new(Layout::KEYS);
        t.cmp(0);
        t.side(0); // entry 0 of ANOTHER array: a second line, not key line 0
        t.side(15); // sixteen 4-byte entries share a line
        t.side(16);
        assert_eq!(t.key_lines(), 1);
        assert_eq!(t.side_lines(), 2);
        assert_eq!(t.lines_read(), 3);
        assert_eq!(t.uncovered, 3);
        assert_eq!(t.comparisons, 1); // a side read is not a comparison
    }
}
