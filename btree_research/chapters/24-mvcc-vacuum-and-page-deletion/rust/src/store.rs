//! The version store ("the heap"): row versions, the transaction counter and
//! the list of open snapshots. Visibility is decided HERE, outside the index;
//! the index only stores (user key, tid) pairs that point into this store.
//!
//! The whole MVCC model of the chapter is three rules:
//!
//!   1. Every write is a transaction and gets the next number from one
//!      counter (`now`). The same counter serves as the EPOCH that page
//!      deletion stamps on a page.
//!   2. A row version records the transaction that created it (`xmin`) and
//!      the one that deleted or replaced it (`xmax`, 0 = nobody yet).
//!   3. A snapshot is the value of the counter when the reader started.
//!      It sees a version iff  xmin <= snapshot  and  (xmax == 0 or xmax > snapshot).
//!
//! Simplification, stated once: every transaction here commits at once and
//! none aborts, so "xid <= snapshot" is the whole visibility test. A real
//! system also has to ask whether xmin / xmax committed, aborted or are still
//! running.

use crate::base_arena::{Arena, NodeId};

/// Tuple id: handle of a row version. Slots are reused after VACUUM frees
/// them, which is why an index entry must be gone BEFORE its version is freed.
pub type Tid = NodeId;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Version {
    pub key: u64,
    pub value: u64,
    pub xmin: u64,
    pub xmax: u64,
}

impl Version {
    pub fn visible(&self, snapshot: u64) -> bool {
        self.xmin <= snapshot && (self.xmax == 0 || self.xmax > snapshot)
    }
}

pub const MAX_SNAPSHOTS: usize = 16;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TooManySnapshots;

#[derive(Debug, Default)]
pub struct Store {
    pub versions: Arena<Version>,
    /// Last transaction id handed out. Also the current epoch.
    pub now: u64,
    /// Open snapshots, in no particular order (a small multiset).
    pub open: Vec<u64>,
}

impl Store {
    /// Starts (and, in this model, immediately commits) a transaction.
    pub fn tick(&mut self) -> u64 {
        self.now += 1;
        self.now
    }

    /// A reader registers its snapshot so that garbage collection knows which
    /// old versions and which deleted pages somebody may still need.
    pub fn open_snapshot(&mut self) -> Result<u64, TooManySnapshots> {
        if self.open.len() == MAX_SNAPSHOTS {
            return Err(TooManySnapshots);
        }
        self.open.push(self.now);
        Ok(self.now)
    }

    pub fn close_snapshot(&mut self, snapshot: u64) {
        let i = self.open.iter().position(|&s| s == snapshot);
        self.open.swap_remove(i.expect("snapshot is open"));
    }

    pub fn is_open(&self, snapshot: u64) -> bool {
        self.open.contains(&snapshot)
    }

    /// The oldest snapshot anybody holds; `now` if nobody holds one, because
    /// every future snapshot will be >= now. Everything garbage collection
    /// does is justified by comparing against this number.
    pub fn horizon(&self) -> u64 {
        self.open.iter().fold(self.now, |h, &s| h.min(s))
    }

    /// Dead to everyone: deleted at or before the horizon, so no open and no
    /// future snapshot can see it. (Compare with `visible`: xmax <= horizon
    /// <= snapshot fails the second half of the test for every snapshot.)
    pub fn dead_to_all(&self, tid: Tid) -> bool {
        let v = self.versions.get(tid);
        v.xmax != 0 && v.xmax <= self.horizon()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn visibility_is_two_comparisons() {
        let v = Version { key: 1, value: 1, xmin: 5, xmax: 9 };
        assert!(!v.visible(4)); // created later
        assert!(v.visible(5));
        assert!(v.visible(8));
        assert!(!v.visible(9)); // deleted by then
        let live = Version { key: 1, value: 1, xmin: 5, xmax: 0 };
        assert!(live.visible(1000));
    }

    #[test]
    fn the_horizon_is_the_oldest_open_snapshot_or_now() {
        let mut s = Store::default();
        s.tick();
        s.tick();
        assert_eq!(s.horizon(), 2);
        let a = s.open_snapshot().unwrap(); // 2
        s.tick();
        let b = s.open_snapshot().unwrap(); // 3
        s.tick();
        assert_eq!(s.horizon(), 2);
        s.close_snapshot(a);
        assert_eq!(s.horizon(), 3);
        s.close_snapshot(b);
        assert_eq!(s.horizon(), 4);
        for _ in 0..MAX_SNAPSHOTS {
            s.open_snapshot().unwrap();
        }
        assert_eq!(s.open_snapshot(), Err(TooManySnapshots));
    }
}
