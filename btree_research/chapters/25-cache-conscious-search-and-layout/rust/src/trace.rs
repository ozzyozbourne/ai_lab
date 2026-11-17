//! A cache-line accounting model (twin of zig/src/trace.zig).
//!
//! Chapter 01 counted page reads instead of comparisons. This chapter zooms in
//! one level: inside a page (or inside any in-memory array) the unit of cost
//! is the 64-byte cache line. Every search algorithm in this chapter takes a
//! `Tracer` and reports each key it looks at. Two tracers exist:
//!
//!   * `NoTrace`: every method is empty; after monomorphisation and inlining
//!     nothing is left of the calls. This is the code you would ship.
//!   * `Trace`: counts comparisons and remembers which cache lines were read.
//!
//! Because the same generic function runs with both, the counted algorithm
//! cannot drift from the fast one. The model is deliberately simple: it
//! assumes the array starts on a cache-line boundary and it knows nothing
//! about TLBs, the hardware prefetcher or cache sizes. It produces counts,
//! never timings.

/// Bytes per cache line on every mainstream x86-64 and most AArch64 CPUs.
pub const LINE_BYTES: usize = 64;
/// u64 keys that fit in one line; also the chunk size of the "vector" scan.
pub const LANES: usize = LINE_BYTES / size_of::<u64>();
/// Largest array the model can describe: 2048 lines = 128 KiB.
pub const MAX_LINES: usize = 2048;
/// How many probe positions a trace remembers (enough for any binary search).
pub const MAX_PROBES: usize = 16;

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
        assert!(line < MAX_LINES);
        let bit = 1u64 << (line % 64);
        let fresh = self.words[line / 64] & bit == 0;
        self.words[line / 64] |= bit;
        self.count += u32::from(fresh);
        fresh
    }

    pub fn contains(&self, line: usize) -> bool {
        self.words[line / 64] & (1u64 << (line % 64)) != 0
    }
}

/// What a search reports while it runs. Zig passes `tracer: anytype` and
/// resolves the calls by duck typing at compile time; Rust names the contract.
pub trait Tracer {
    /// One scalar comparison against element `index`.
    fn cmp(&mut self, index: usize);
    /// One chunk ("vector") comparison against `count` elements from `index`.
    fn cmp_block(&mut self, index: usize, count: usize);
    /// A prefetch hint for the line holding element `index`.
    fn prefetch(&mut self, index: usize);
}

#[derive(Debug, Clone)]
pub struct Trace {
    pub layout: Layout,
    /// Key comparisons. A chunk compare of 8 lanes counts as 8.
    pub comparisons: u32,
    /// Compare instructions: 1 per scalar compare, 1 per 8-lane compare.
    pub steps: u32,
    /// Prefetch hints issued.
    pub prefetches: u32,
    /// Distinct lines the comparisons read.
    pub read: LineSet,
    /// Distinct lines named by prefetch hints.
    pub hinted: LineSet,
    /// Lines read for the first time that no earlier hint had asked for. On a
    /// cold cache each of these is a miss the CPU must wait for before it can
    /// even compute the next address. Hinted lines are already on their way.
    pub uncovered: u32,
    /// The first `MAX_PROBES` element indexes compared, for the hand example.
    probes: [u32; MAX_PROBES],
    probe_len: usize,
}

impl Trace {
    pub fn new(layout: Layout) -> Self {
        Self {
            layout,
            comparisons: 0,
            steps: 0,
            prefetches: 0,
            read: LineSet::new(),
            hinted: LineSet::new(),
            uncovered: 0,
            probes: [0; MAX_PROBES],
            probe_len: 0,
        }
    }

    pub fn lines_read(&self) -> u32 {
        self.read.count
    }

    pub fn probes(&self) -> &[u32] {
        &self.probes[..self.probe_len]
    }

    fn read_line(&mut self, line: usize) {
        if self.read.insert(line) && !self.hinted.contains(line) {
            self.uncovered += 1;
        }
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
    }

    fn cmp_block(&mut self, index: usize, count: usize) {
        self.comparisons += count as u32;
        self.steps += 1;
        self.note(index);
        for line in self.layout.line_of(index)..=self.layout.line_of(index + count - 1) {
            self.read_line(line);
        }
    }

    fn prefetch(&mut self, index: usize) {
        self.prefetches += 1;
        self.hinted.insert(self.layout.line_of(index));
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

        t.prefetch(100); // line 12, hinted before it is read
        t.cmp(100);
        assert_eq!(t.lines_read(), 3);
        assert_eq!(t.uncovered, 2); // the hinted line is covered

        t.cmp_block(16, 8); // one instruction, eight lanes, one line
        assert_eq!(t.comparisons, 12);
        assert_eq!(t.steps, 5);
        assert_eq!(t.lines_read(), 4);
        assert_eq!(t.probes(), &[0, 7, 8, 100, 16]);
    }
}
