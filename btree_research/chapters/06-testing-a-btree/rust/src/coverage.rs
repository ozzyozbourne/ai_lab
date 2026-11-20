//! Coverage points: "did the test actually go there?"
//!
//! A fuzzer that never fails proves little if it never reached the hard
//! branches. So the tree counts how often each structurally interesting
//! branch ran, and the fuzz tests ASSERT at the end that every counter is
//! non-zero (TigerBeetle does the same with `assert(tested_padding)`, see the
//! README). The branches are marked in base_insert.rs and base_delete.rs
//! with `tree.coverage.hit(Point::...)`.
//!
//! This replaces chapter 05's `Counters`: the same idea, but split by level
//! (leaf / interior), because "a split happened" does not say whether a split
//! of an INTERIOR node, with its children to move, was ever exercised.

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Point {
    // base_insert.rs
    PutFirstKey,  // empty tree: the root leaf is created
    PutOverwrite, // key already present: value replaced, no structural change
    PutNoSplit,   // new key fits into its leaf
    SplitLeaf,
    SplitInterior,     // children move with their keys
    RootSplitLeaf,     // height 1 -> 2
    RootSplitInterior, // height n -> n + 1, n >= 2
    PutOom,            // allocation failed before anything was reserved
    PutOomRollback,    // allocation failed with nodes already reserved: they are handed back
    // base_delete.rs
    DeleteMissing,
    DeleteLeafKey,
    DeleteInteriorKey, // replaced by its in-order predecessor
    BorrowLeftLeaf,
    BorrowLeftInterior, // a child pointer changes parent as well
    BorrowRightLeaf,
    BorrowRightInterior,
    MergeLeaf,
    MergeInterior,
    MergeFirstChild, // the underfull node has no left sibling: merge with the right one
    RootShrink,      // height n -> n - 1
    TreeEmptied,     // the last key was deleted
}

pub const POINT_COUNT: usize = 21;

impl Point {
    /// Every point, in declaration order (Rust has no built-in enum iteration).
    pub const ALL: [Point; POINT_COUNT] = [
        Point::PutFirstKey,
        Point::PutOverwrite,
        Point::PutNoSplit,
        Point::SplitLeaf,
        Point::SplitInterior,
        Point::RootSplitLeaf,
        Point::RootSplitInterior,
        Point::PutOom,
        Point::PutOomRollback,
        Point::DeleteMissing,
        Point::DeleteLeafKey,
        Point::DeleteInteriorKey,
        Point::BorrowLeftLeaf,
        Point::BorrowLeftInterior,
        Point::BorrowRightLeaf,
        Point::BorrowRightInterior,
        Point::MergeLeaf,
        Point::MergeInterior,
        Point::MergeFirstChild,
        Point::RootShrink,
        Point::TreeEmptied,
    ];

    /// The name used in the program output (same spelling as the Zig enum).
    pub fn name(self) -> &'static str {
        match self {
            Point::PutFirstKey => "put_first_key",
            Point::PutOverwrite => "put_overwrite",
            Point::PutNoSplit => "put_no_split",
            Point::SplitLeaf => "split_leaf",
            Point::SplitInterior => "split_interior",
            Point::RootSplitLeaf => "root_split_leaf",
            Point::RootSplitInterior => "root_split_interior",
            Point::PutOom => "put_oom",
            Point::PutOomRollback => "put_oom_rollback",
            Point::DeleteMissing => "delete_missing",
            Point::DeleteLeafKey => "delete_leaf_key",
            Point::DeleteInteriorKey => "delete_interior_key",
            Point::BorrowLeftLeaf => "borrow_left_leaf",
            Point::BorrowLeftInterior => "borrow_left_interior",
            Point::BorrowRightLeaf => "borrow_right_leaf",
            Point::BorrowRightInterior => "borrow_right_interior",
            Point::MergeLeaf => "merge_leaf",
            Point::MergeInterior => "merge_interior",
            Point::MergeFirstChild => "merge_first_child",
            Point::RootShrink => "root_shrink",
            Point::TreeEmptied => "tree_emptied",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct Coverage {
    pub hits: [u64; POINT_COUNT],
}

impl Coverage {
    pub fn hit(&mut self, point: Point) {
        self.hits[point as usize] += 1;
    }

    pub fn count(&self, point: Point) -> u64 {
        self.hits[point as usize]
    }

    /// Fold another tree's counters into this one (one fuzz run = many trees).
    pub fn add(&mut self, other: &Coverage) {
        for (mine, theirs) in self.hits.iter_mut().zip(other.hits) {
            *mine += theirs;
        }
    }

    /// Number of points with at least one hit.
    pub fn reached(&self) -> usize {
        self.hits.iter().filter(|&&h| h > 0).count()
    }

    /// The first point that was never hit, or `None` if every branch ran.
    pub fn first_missing(&self) -> Option<Point> {
        Point::ALL.into_iter().find(|&p| self.count(p) == 0)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hit_count_add_reached_first_missing() {
        let mut a = Coverage::default();
        assert_eq!(a.first_missing(), Some(Point::PutFirstKey));
        a.hit(Point::SplitLeaf);
        a.hit(Point::SplitLeaf);
        let mut b = Coverage::default();
        b.hit(Point::MergeLeaf);
        b.add(&a);
        assert_eq!(b.count(Point::SplitLeaf), 2);
        assert_eq!(b.count(Point::MergeLeaf), 1);
        assert_eq!(b.reached(), 2);
        for point in Point::ALL {
            b.hit(point);
        }
        assert_eq!(b.first_missing(), None);
        assert_eq!(b.reached(), POINT_COUNT);
    }

    #[test]
    fn all_lists_every_point_in_declaration_order() {
        for (i, point) in Point::ALL.into_iter().enumerate() {
            assert_eq!(point as usize, i);
        }
        assert_eq!(Point::TreeEmptied as usize, POINT_COUNT - 1);
    }
}
