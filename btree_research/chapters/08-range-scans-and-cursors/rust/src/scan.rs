//! `Scan`: a range scan = one seek + steps + a stop test.
//!
//!   forward:  seek to the LOWER bound, step `next`, stop at the first key
//!             outside the UPPER bound;
//!   backward: seek to the UPPER bound, step `prev`, stop at the first key
//!             outside the LOWER bound.
//!
//! Only the far bound is tested per entry. The near bound is satisfied by
//! the seek and stays satisfied, because keys only move away from it.
//!
//! `Scan` is generic over the cursor's position type, so the same code runs
//! on the link cursor and on the stack cursor. Because cursors re-seek by
//! key, a scan keeps working when entries are inserted or deleted between
//! two `next` calls. What it returns then: every entry that was in the range
//! for the whole scan exactly once, in order; an entry inserted or deleted
//! during the scan is returned if and only if the scan had not passed its
//! key yet.
//!
//! Two shapes, because of the borrow checker:
//!   * `Scan<P>` does not borrow the tree; `scan.next(&tree)` takes it per
//!     call, so the tree may be changed between calls;
//!   * `ScanIter<'a, P>` borrows the tree and is a normal `Iterator`; while
//!     it lives the compiler rejects every `put` and `delete`.
//!
//! In Zig one type does both jobs (it stores a `*const Tree`).

use std::ops::RangeBounds;

use crate::base_node::Entry;
use crate::bounds::{Bound, Direction, above_lower, below_upper};
use crate::cursor::{Cursor, Position, Seek};
use crate::tree::Tree;

/// Which seek puts a cursor on the first entry of the scan.
pub fn start_seek(lo: Bound<u64>, hi: Bound<u64>, direction: Direction) -> Seek {
    match direction {
        Direction::Forward => match lo {
            Bound::Unbounded => Seek::First,
            Bound::Included(k) => Seek::Ge(k),
            Bound::Excluded(k) => Seek::Gt(k),
        },
        Direction::Backward => match hi {
            Bound::Unbounded => Seek::Last,
            Bound::Included(k) => Seek::Le(k),
            Bound::Excluded(k) => Seek::Lt(k),
        },
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Phase {
    Start,
    Running,
    Done,
}

#[derive(Debug, Clone)]
pub struct Scan<P> {
    pub cursor: Cursor<P>,
    lo: Bound<u64>,
    hi: Bound<u64>,
    direction: Direction,
    phase: Phase,
}

impl<P: Position> Scan<P> {
    pub fn new(cursor: Cursor<P>, range: impl RangeBounds<u64>, direction: Direction) -> Self {
        Scan {
            cursor,
            lo: range.start_bound().cloned(),
            hi: range.end_bound().cloned(),
            direction,
            phase: Phase::Start,
        }
    }

    #[allow(clippy::should_implement_trait)] // see ScanIter for the Iterator
    pub fn next(&mut self, tree: &Tree) -> Option<Entry> {
        let candidate = match self.phase {
            Phase::Done => return None,
            Phase::Start => self
                .cursor
                .seek(tree, start_seek(self.lo, self.hi, self.direction)),
            Phase::Running => match self.direction {
                Direction::Forward => self.cursor.next(tree),
                Direction::Backward => self.cursor.prev(tree),
            },
        };
        self.phase = Phase::Running;
        if let Some(found) = candidate {
            let inside = match self.direction {
                Direction::Forward => below_upper(self.hi, found.key),
                Direction::Backward => above_lower(self.lo, found.key),
            };
            if inside {
                return Some(found);
            }
        }
        // Past the far bound or off the end of the tree. An empty or
        // inverted range needs no special case: its first candidate already
        // fails the test.
        self.phase = Phase::Done;
        None
    }

    /// Runs the scan to its end, replacing the contents of `out`. Reusing
    /// one `out` across scans is Rust's version of a per-scan arena that is
    /// reset with its capacity retained.
    pub fn collect_into(&mut self, tree: &Tree, out: &mut Vec<Entry>) {
        out.clear();
        while let Some(found) = self.next(tree) {
            out.push(found);
        }
    }

    /// Borrows the tree for the rest of the scan and becomes an `Iterator`.
    pub fn iter(self, tree: &Tree) -> ScanIter<'_, P> {
        ScanIter { tree, scan: self }
    }
}

pub struct ScanIter<'a, P> {
    tree: &'a Tree,
    pub scan: Scan<P>,
}

impl<P: Position> Iterator for ScanIter<'_, P> {
    type Item = Entry;

    fn next(&mut self) -> Option<Entry> {
        self.scan.next(self.tree)
    }
}
