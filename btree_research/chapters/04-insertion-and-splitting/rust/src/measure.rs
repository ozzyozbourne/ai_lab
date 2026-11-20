//! Measurements: how full are the nodes after N inserts, and how many splits
//! did the inserts cost? Counts only, no timings.
//!
//! Two numbers are worth knowing before reading the output of `run`:
//!
//! * a tree in which every node is at the legal minimum is about 50% full,
//!   a tree of full nodes is 100% full;
//! * textbook result (Yao, 1978): under random insertions the expected fill
//!   of a B-tree approaches ln 2 = 69.3% as the order grows.
//!
//! The scenario prints what THIS code measures next to those references.

use crate::base_btree::BTree;
use crate::base_pool::OutOfNodes;
use crate::base_stats::Shape;
use crate::prng::SplitMix64;
use crate::topdown;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum KeyOrder {
    Ascending,
    Random,
}

impl KeyOrder {
    /// The word used in the output table (Zig: `@tagName`).
    pub fn name(self) -> &'static str {
        match self {
            KeyOrder::Ascending => "ascending",
            KeyOrder::Random => "random",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Variant {
    BottomUp,
    TopDown,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Measured {
    /// Number of puts (all keys are distinct, so also the number of keys).
    pub puts: usize,
    pub shape: Shape,
    pub splits: u64,
    pub root_splits: u64,
    /// The worst single put: how many nodes it split.
    pub most_splits_in_one_put: u64,
}

impl Measured {
    /// Average node fill in tenths of a percent: keys / (nodes * (M - 1)).
    pub fn fill_permille(&self) -> usize {
        (self.shape.keys * 1000)
            .checked_div(self.shape.capacity)
            .unwrap_or(0)
    }

    /// Splits per 1000 puts, in tenths (so 345 means 34.5 splits per 1000 puts).
    /// This is the amortised structural cost of one insert.
    pub fn splits_per_1000_tenths(&self) -> usize {
        (self.splits * 10_000)
            .checked_div(self.puts as u64)
            .unwrap_or(0) as usize
    }
}

/// The keys 0, 1, ..., n - 1, shuffled for `KeyOrder::Random`.
pub fn fill_keys(n: usize, order: KeyOrder, seed: u64) -> Vec<u64> {
    let mut keys: Vec<u64> = (0..n as u64).collect();
    if order == KeyOrder::Random {
        SplitMix64::new(seed).shuffle(&mut keys);
    }
    keys
}

/// Insert `keys` (distinct) into an empty tree of the given order and report
/// its shape and split counts.
pub fn build(order: usize, variant: Variant, keys: &[u64]) -> Result<Measured, OutOfNodes> {
    let mut tree = BTree::new(order);
    let mut most = 0;
    for &key in keys {
        let before = tree.counters.splits;
        let old = match variant {
            Variant::BottomUp => tree.put(key, key)?,
            Variant::TopDown => topdown::put(&mut tree, key, key)?,
        };
        debug_assert!(old.is_none()); // keys are distinct
        most = most.max(tree.counters.splits - before);
    }
    debug_assert_eq!(tree.validate(), Ok(()));
    Ok(Measured {
        puts: keys.len(),
        shape: tree.shape(),
        splits: tree.counters.splits,
        root_splits: tree.counters.root_splits,
        most_splits_in_one_put: most,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn split_accounting_every_split_adds_one_node_every_root_split_one_more_and_one_level() {
        for order_of_keys in [KeyOrder::Ascending, KeyOrder::Random] {
            let keys = fill_keys(3000, order_of_keys, 4);
            for order in [3, 4, 5, 8, 16] {
                let r = build(order, Variant::BottomUp, &keys).unwrap();
                assert_eq!(r.shape.keys, keys.len());
                assert_eq!(r.shape.nodes as u64, 1 + r.splits + r.root_splits);
                assert_eq!(r.shape.height as u64, 1 + r.root_splits);
                // No single put splits more nodes than the tree is high ...
                assert!(r.most_splits_in_one_put <= r.shape.height as u64);
                // ... and on average far fewer: every non-root node keeps at
                // least min_keys = ceil(M/2) - 1 keys, so there are fewer than
                // N / min_keys nodes, and each split made one of them.
                let min_keys = order.div_ceil(2) - 1;
                assert!(r.splits < (keys.len() / min_keys) as u64);
            }
        }
    }

    #[test]
    fn ascending_inserts_leave_every_left_half_at_its_split_size() {
        // With M = 4 an overfull node of 4 keys splits 2 + median + 1. Nothing
        // is ever inserted into a left half again, so all leaves except the
        // last keep 2 of 3 slots: two thirds full, not one half.
        let keys = fill_keys(3000, KeyOrder::Ascending, 0);
        let r4 = build(4, Variant::BottomUp, &keys).unwrap();
        assert!((640..=670).contains(&r4.fill_permille()));
        // With M = 64 the left half keeps 32 of 63 slots: about one half.
        let r64 = build(64, Variant::BottomUp, &keys).unwrap();
        assert!((490..=530).contains(&r64.fill_permille()));
    }

    #[test]
    fn random_inserts_fill_nodes_better_than_ascending_inserts() {
        let asc = fill_keys(20_000, KeyOrder::Ascending, 0);
        let rnd = fill_keys(20_000, KeyOrder::Random, 4);
        for order in [8, 16, 64] {
            let a = build(order, Variant::BottomUp, &asc).unwrap();
            let r = build(order, Variant::BottomUp, &rnd).unwrap();
            assert!(r.fill_permille() > a.fill_permille());
            // Loose band around the textbook ln 2 = 69.3%; the scenario
            // prints the exact measured values.
            assert!(r.fill_permille() > 600 && r.fill_permille() < 780);
        }
    }

    #[test]
    fn top_down_holds_the_same_keys_ascending_keys_at_m_4_leave_it_one_third_full() {
        for order_of_keys in [KeyOrder::Ascending, KeyOrder::Random] {
            let keys = fill_keys(20_000, order_of_keys, 4);
            for order in [4, 8, 64] {
                let bottom = build(order, Variant::BottomUp, &keys).unwrap();
                let top = build(order, Variant::TopDown, &keys).unwrap();
                assert_eq!(bottom.shape.keys, top.shape.keys);
                assert_eq!(top.shape.nodes as u64, 1 + top.splits + top.root_splits);
                // Which variant splits more often is NOT fixed (the scenario
                // has a row where top-down needs one split fewer), so no
                // assertion on that. What does hold: a put splits at most
                // one node per level.
                assert!(top.most_splits_in_one_put <= top.shape.height as u64);
            }
        }
        // With M = 4 a top-down split leaves 1 + 1 keys in nodes of 3 slots,
        // and ascending keys never refill a left half: one third full.
        let keys = fill_keys(20_000, KeyOrder::Ascending, 0);
        let worst = build(4, Variant::TopDown, &keys).unwrap();
        assert!((330..=340).contains(&worst.fill_permille()));
    }
}
