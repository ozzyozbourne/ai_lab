//! Tests of chapter 08: the bounds matrix, both cursor designs, backward
//! scans, prefix scans, cursors under a changing tree, buffer reuse, the
//! node budget, and the seeded model run.
//! (bounds.rs, cursor.rs and the copied base files carry their own tests.)

use std::ops::Bound::{self, Excluded, Included, Unbounded};

use crate::base_arena::{NodeId, OutOfNodes};
use crate::base_node::Entry;
use crate::base_validate::Violation;
use crate::base_walk::LeafWalker;
use crate::bounds::{Direction, contains, prefix_range};
use crate::cursor::{Cursor, Position, Seek, State, Stats};
use crate::link_cursor::{LinkCursor, LinkPosition};
use crate::model;
use crate::scan::Scan;
use crate::stack_cursor::{Frame, MAX_DEPTH, StackCursor, StackPosition};
use crate::tree::Tree;

const CANONICAL: [u64; 12] = [10, 20, 5, 6, 12, 30, 7, 17, 3, 25, 1, 15];
const SORTED: [u64; 12] = [1, 3, 5, 6, 7, 10, 12, 15, 17, 20, 25, 30];

fn build_canonical() -> Tree {
    let mut tree = Tree::new(4);
    for k in CANONICAL {
        tree.put(k, k * 100).unwrap();
    }
    tree.validate().unwrap();
    tree
}

/// One cursor of each design.
struct Pair {
    link: LinkCursor,
    stack: StackCursor,
}

// Each helper applies one operation to both cursors, demands the same answer
// from both, and returns the key (None = no entry).
impl Pair {
    fn new() -> Pair {
        Pair {
            link: Cursor::new(LinkPosition::new()),
            stack: Cursor::new(StackPosition::new()),
        }
    }
    fn seek(&mut self, tree: &Tree, target: Seek) -> Option<u64> {
        agree(self.link.seek(tree, target), self.stack.seek(tree, target))
    }
    fn next(&mut self, tree: &Tree) -> Option<u64> {
        agree(self.link.next(tree), self.stack.next(tree))
    }
    fn prev(&mut self, tree: &Tree) -> Option<u64> {
        agree(self.link.prev(tree), self.stack.prev(tree))
    }
    fn entry(&mut self, tree: &Tree) -> Option<u64> {
        agree(self.link.entry(tree), self.stack.entry(tree))
    }
}

fn agree(a: Option<Entry>, b: Option<Entry>) -> Option<u64> {
    assert_eq!(a, b);
    a.map(|e| e.key)
}

/// The keys a scan returns, with a cursor on position type `P`.
fn scan_keys<P: Position>(
    pos: P,
    tree: &Tree,
    lo: Bound<u64>,
    hi: Bound<u64>,
    direction: Direction,
) -> Vec<u64> {
    let mut scan = Scan::new(Cursor::new(pos), (lo, hi), direction);
    let mut keys = Vec::new();
    while let Some(e) = scan.next(tree) {
        assert_eq!(e.value, e.key * 100);
        keys.push(e.key);
    }
    assert_eq!(scan.next(tree), None); // a finished scan stays finished
    keys
}

fn make_bound(kind: usize, key: u64) -> Bound<u64> {
    match kind {
        0 => Unbounded,
        1 => Included(key),
        _ => Excluded(key),
    }
}

#[test]
fn bounds_matrix_every_lo_hi_kind_and_value_both_cursors_both_directions() {
    let tree = build_canonical();
    let mut checked = 0;
    for lo_kind in 0..3 {
        for hi_kind in 0..3 {
            for lo_key in 0..33 {
                for hi_key in 0..33 {
                    let lo = make_bound(lo_kind, lo_key);
                    let hi = make_bound(hi_kind, hi_key);
                    // The specification: filter the sorted keys by `contains`.
                    let mut expected: Vec<u64> = SORTED
                        .into_iter()
                        .filter(|&k| contains(lo, hi, k))
                        .collect();

                    let forward = Direction::Forward;
                    assert_eq!(
                        scan_keys(LinkPosition::new(), &tree, lo, hi, forward),
                        expected
                    );
                    assert_eq!(
                        scan_keys(StackPosition::new(), &tree, lo, hi, forward),
                        expected
                    );
                    expected.reverse();
                    let backward = Direction::Backward;
                    assert_eq!(
                        scan_keys(LinkPosition::new(), &tree, lo, hi, backward),
                        expected
                    );
                    assert_eq!(
                        scan_keys(StackPosition::new(), &tree, lo, hi, backward),
                        expected
                    );
                    checked += 1;
                }
            }
        }
    }
    assert_eq!(checked, 9 * 33 * 33);
}

#[test]
fn tree_range_and_tree_range_backward_on_the_readme_examples() {
    let tree = build_canonical();

    let entries: Vec<Entry> = tree.range(6..17).collect();
    let keys: Vec<u64> = entries.iter().map(|e| e.key).collect();
    assert_eq!(keys, [6, 7, 10, 12, 15]);
    assert!(entries.iter().all(|e| e.value == e.key * 100));

    let back: Vec<u64> = tree
        .range_backward((Excluded(6), Included(17)))
        .map(|e| e.key)
        .collect();
    assert_eq!(back, [17, 15, 12, 10, 7]);

    // Range syntax covers six of the nine combinations; an excluded lower
    // bound needs the tuple form.
    assert_eq!(tree.range(..).count(), 12);
    assert_eq!(tree.range(..=17).count(), 9);
    assert_eq!(tree.range(..17).count(), 8);
    assert_eq!(tree.range(6..).count(), 9);
    assert_eq!(tree.range(6..=17).count(), 6);
    assert_eq!(tree.range((Excluded(6), Unbounded)).count(), 8);

    // Excluded bounds at the ends of the key space: no overflow, just empty.
    assert_eq!(tree.range((Excluded(u64::MAX), Unbounded)).next(), None);
    assert_eq!(tree.range_backward(..0).next(), None);
    // Unlike `BTreeMap::range`, an inverted range does not panic: it is empty.
    assert_eq!(tree.range((Included(17), Included(6))).next(), None);
}

/// Keys and probes for the two ends of the key space.
const MAX: u64 = u64::MAX;
const EXTREME_KEYS: [u64; 8] = [0, 1, 2, 500, 1 << 40, MAX - 2, MAX - 1, MAX];
const EXTREME_PROBES: [u64; 9] = [0, 1, 2, 3, 500, MAX - 3, MAX - 2, MAX - 1, MAX];

/// A tree that really stores 0 and `u64::MAX`, inserted from both ends
/// inward. The value is `!key` (`key * 100` would overflow).
fn build_extremes(order: usize) -> Tree {
    let mut tree = Tree::new(order);
    for k in [MAX, 0, MAX - 1, 1, 500, MAX - 2, 2, 1 << 40] {
        tree.put(k, !k).unwrap();
    }
    tree.validate().unwrap();
    tree
}

/// One scan over the tree of `build_extremes`, compared with `expected`.
fn expect_extreme_scan<P: Position>(
    pos: P,
    tree: &Tree,
    bounds: (Bound<u64>, Bound<u64>),
    direction: Direction,
    expected: &[u64],
) {
    let mut scan = Scan::new(Cursor::new(pos), bounds, direction);
    for &k in expected {
        assert_eq!(scan.next(tree), Some(Entry { key: k, value: !k }));
    }
    assert_eq!(scan.next(tree), None);
    assert_eq!(scan.next(tree), None);
}

#[test]
fn u64_extremes_stored_in_the_tree_0_1_max_1_and_max_under_every_bound_kind() {
    for order in [3, 4, 16] {
        let mut tree = build_extremes(order);

        let mut checked = 0;
        for lo_kind in 0..3 {
            for hi_kind in 0..3 {
                for lo_key in EXTREME_PROBES {
                    for hi_key in EXTREME_PROBES {
                        let lo = make_bound(lo_kind, lo_key);
                        let hi = make_bound(hi_kind, hi_key);
                        let mut expected: Vec<u64> = EXTREME_KEYS
                            .into_iter()
                            .filter(|&k| contains(lo, hi, k))
                            .collect();

                        let forward = Direction::Forward;
                        expect_extreme_scan(
                            LinkPosition::new(),
                            &tree,
                            (lo, hi),
                            forward,
                            &expected,
                        );
                        expect_extreme_scan(
                            StackPosition::new(),
                            &tree,
                            (lo, hi),
                            forward,
                            &expected,
                        );
                        expected.reverse();
                        let backward = Direction::Backward;
                        expect_extreme_scan(
                            LinkPosition::new(),
                            &tree,
                            (lo, hi),
                            backward,
                            &expected,
                        );
                        expect_extreme_scan(
                            StackPosition::new(),
                            &tree,
                            (lo, hi),
                            backward,
                            &expected,
                        );
                        checked += 1;
                    }
                }
            }
        }
        assert_eq!(checked, 9 * EXTREME_PROBES.len() * EXTREME_PROBES.len());

        // Seeks at the two ends: "greater than the largest u64" and "less
        // than 0" have no answer, and must not wrap around to find one.
        let mut pair = Pair::new();
        assert_eq!(pair.seek(&tree, Seek::Gt(MAX)), None);
        assert_eq!(pair.link.state, State::AfterLast);
        assert_eq!(pair.seek(&tree, Seek::Ge(MAX)), Some(MAX));
        assert_eq!(pair.seek(&tree, Seek::Le(MAX)), Some(MAX));
        assert_eq!(pair.seek(&tree, Seek::Lt(MAX)), Some(MAX - 1));
        assert_eq!(pair.next(&tree), Some(MAX));
        assert_eq!(pair.next(&tree), None);
        assert_eq!(pair.prev(&tree), Some(MAX));

        assert_eq!(pair.seek(&tree, Seek::Lt(0)), None);
        assert_eq!(pair.stack.state, State::BeforeFirst);
        assert_eq!(pair.seek(&tree, Seek::Le(0)), Some(0));
        assert_eq!(pair.seek(&tree, Seek::Ge(0)), Some(0));
        assert_eq!(pair.seek(&tree, Seek::Gt(0)), Some(1));
        assert_eq!(pair.prev(&tree), Some(0));
        assert_eq!(pair.prev(&tree), None);
        assert_eq!(pair.next(&tree), Some(0));

        // Delete the entry under the cursor at each end: the saved key still
        // says where to continue.
        assert_eq!(pair.seek(&tree, Seek::Last), Some(MAX));
        assert_eq!(tree.delete(MAX), Some(!MAX));
        assert_eq!(pair.entry(&tree), None);
        assert_eq!(pair.prev(&tree), Some(MAX - 1));
        assert_eq!(pair.seek(&tree, Seek::First), Some(0));
        assert_eq!(tree.delete(0), Some(!0));
        assert_eq!(pair.next(&tree), Some(1));
        tree.validate().unwrap();
    }
}

#[test]
fn seek_ge_gt_le_lt_on_present_keys_gaps_separators_and_both_ends() {
    let mut tree = build_canonical();
    let mut pair = Pair::new();

    // probe, expected ge, gt, le, lt (0 = no entry). 6, 10, 15 and 20 are
    // separators: the descent goes right of them and the leaf step must
    // still find the neighbour on the left for `lt`.
    let table: [[u64; 5]; 12] = [
        [0, 1, 1, 0, 0],
        [1, 1, 3, 1, 0],
        [2, 3, 3, 1, 1],
        [5, 5, 6, 5, 3],
        [6, 6, 7, 6, 5],
        [8, 10, 10, 7, 7],
        [10, 10, 12, 10, 7],
        [13, 15, 15, 12, 12],
        [15, 15, 17, 15, 12],
        [20, 20, 25, 20, 17],
        [30, 30, 0, 30, 25],
        [31, 0, 0, 30, 30],
    ];
    let or_none = |key: u64| (key != 0).then_some(key);
    for [p, ge, gt, le, lt] in table {
        assert_eq!(pair.seek(&tree, Seek::Ge(p)), or_none(ge));
        assert_eq!(pair.seek(&tree, Seek::Gt(p)), or_none(gt));
        assert_eq!(pair.seek(&tree, Seek::Le(p)), or_none(le));
        assert_eq!(pair.seek(&tree, Seek::Lt(p)), or_none(lt));
    }
    assert_eq!(pair.seek(&tree, Seek::First), Some(1));
    assert_eq!(pair.seek(&tree, Seek::Last), Some(30));

    // A stale separator: after deleting 15 the root still says 15.
    tree.delete(15);
    assert_eq!(pair.seek(&tree, Seek::Ge(15)), Some(17));
    assert_eq!(pair.seek(&tree, Seek::Le(15)), Some(12));
    assert_eq!(pair.seek(&tree, Seek::Lt(15)), Some(12));
}

#[test]
fn next_and_prev_whole_tree_both_ways_turning_around_both_ends() {
    let tree = build_canonical();
    let mut pair = Pair::new();

    // A new cursor is before the first entry.
    assert_eq!(pair.entry(&tree), None);
    assert_eq!(pair.prev(&tree), None);
    for k in SORTED {
        assert_eq!(pair.next(&tree), Some(k));
        assert_eq!(pair.entry(&tree), Some(k));
    }
    // Off the end: sticky for next, and prev comes back to the last entry.
    assert_eq!(pair.next(&tree), None);
    assert_eq!(pair.next(&tree), None);
    assert_eq!(pair.link.state, State::AfterLast);
    assert_eq!(pair.entry(&tree), None);
    for k in SORTED.into_iter().rev() {
        assert_eq!(pair.prev(&tree), Some(k));
    }
    assert_eq!(pair.prev(&tree), None);
    assert_eq!(pair.stack.state, State::BeforeFirst);

    // Turning around in the middle, across a leaf boundary (7 | 10) and
    // across the boundary between the two subtrees of the root (12 | 15).
    assert_eq!(pair.seek(&tree, Seek::Ge(7)), Some(7));
    assert_eq!(pair.next(&tree), Some(10));
    assert_eq!(pair.prev(&tree), Some(7));
    assert_eq!(pair.next(&tree), Some(10));
    assert_eq!(pair.next(&tree), Some(12));
    assert_eq!(pair.next(&tree), Some(15));
    assert_eq!(pair.prev(&tree), Some(12));
    assert_eq!(pair.next(&tree), Some(15));
    assert_eq!(pair.link.stats.reseeks, 0); // nothing changed, nothing re-sought
    assert_eq!(pair.stack.stats.reseeks, 0);
}

#[test]
fn empty_tree_and_single_entry_tree() {
    let mut tree = Tree::new(4);
    let mut pair = Pair::new();

    let targets = [
        Seek::First,
        Seek::Last,
        Seek::Ge(5),
        Seek::Gt(5),
        Seek::Le(5),
        Seek::Lt(5),
    ];
    for t in targets {
        assert_eq!(pair.seek(&tree, t), None);
    }
    assert_eq!(pair.next(&tree), None);
    assert_eq!(pair.prev(&tree), None);

    tree.put(5, 500).unwrap();
    let expected = [Some(5), Some(5), Some(5), None, Some(5), None];
    for (t, e) in targets.into_iter().zip(expected) {
        assert_eq!(pair.seek(&tree, t), e);
    }
    assert_eq!(pair.seek(&tree, Seek::First), Some(5));
    assert_eq!(pair.next(&tree), None);
    assert_eq!(pair.prev(&tree), Some(5));
    assert_eq!(pair.prev(&tree), None);
    assert_eq!(pair.next(&tree), Some(5));
}

#[test]
fn the_stack_cursors_path_is_the_root_to_leaf_route() {
    let tree = build_canonical();
    let mut pair = Pair::new();
    let frame = |node: usize, child: usize| Frame {
        node: NodeId::from_index(node),
        child,
    };

    //   level 0: #7[15]
    //   level 1: #2[6 10] #6[20]
    //   leaves : #0(1 3 5) #4(6 7) #1(10 12) #5(15 17) #3(20 25 30)
    pair.seek(&tree, Seek::Ge(12));
    assert_eq!(pair.stack.pos.path(), [frame(7, 0), frame(2, 2)]);
    assert_eq!(pair.stack.pos.leaf, NodeId::from_index(1));
    assert_eq!(pair.link.pos.leaf, NodeId::from_index(1));

    // 12 -> 15 crosses the root: pop #2 (exhausted), step #7 to child 1,
    // push #6 with child 0.
    let visits_before = pair.stack.stats.node_visits;
    assert_eq!(pair.next(&tree), Some(15));
    assert_eq!(pair.stack.pos.path(), [frame(7, 1), frame(6, 0)]);
    assert_eq!(pair.stack.pos.leaf, NodeId::from_index(5));
    // Up to #2, up to #7, down to #6, down to #5: four moves, where the
    // link cursor needs one.
    assert_eq!(pair.stack.stats.node_visits - visits_before, 4);
}

#[test]
fn the_stack_cursor_never_uses_sibling_links_the_link_cursor_depends_on_them() {
    let mut tree = build_canonical();

    // Cut the leaf chain and forget both ends. The tree part stays intact.
    let mut id = tree.base.first_leaf;
    while !id.is_nil() {
        let leaf = tree.base.nodes.get_mut(id).leaf_mut();
        let following = leaf.next;
        leaf.next = NodeId::NIL;
        leaf.prev = NodeId::NIL;
        id = following;
    }
    tree.base.first_leaf = NodeId::NIL;
    tree.base.last_leaf = NodeId::NIL;
    assert_eq!(tree.validate(), Err(Violation::BrokenLeafChain));

    let (forward, backward) = (Direction::Forward, Direction::Backward);
    assert_eq!(
        scan_keys(StackPosition::new(), &tree, Unbounded, Unbounded, forward),
        SORTED
    );
    assert_eq!(
        scan_keys(
            StackPosition::new(),
            &tree,
            Excluded(6),
            Included(17),
            backward
        ),
        [17, 15, 12, 10, 7]
    );
    // The link cursor finds the leaf by descent but cannot leave it.
    assert_eq!(
        scan_keys(
            LinkPosition::new(),
            &tree,
            Included(6),
            Included(17),
            forward
        ),
        [6, 7]
    );
    assert_eq!(
        scan_keys(LinkPosition::new(), &tree, Unbounded, Unbounded, forward),
        []
    );
}

#[test]
fn both_cursors_agree_with_the_chapter_07_leaf_walker() {
    let tree = build_canonical();
    let mut pair = Pair::new();
    for from in [0, 6, 8, 15, 31] {
        let mut got = pair.seek(&tree, Seek::Ge(from));
        for e in LeafWalker::seek(&tree.base, from) {
            assert_eq!(got, Some(e.key));
            got = pair.next(&tree);
        }
        assert_eq!(got, None);
    }
}

#[test]
fn prefix_scan_is_a_range_scan() {
    let mut tree = Tree::new(4);
    const LAST_USER: u64 = 0xFFFF_FFFF;
    let rows = [
        (7, 1),
        (3, 2),
        (7, 3),
        (9, 4),
        (7, 5),
        (3, 6),
        (7, 7),
        (LAST_USER, 8),
        (LAST_USER, 9),
    ];
    for (user, row) in rows {
        tree.put((user << 32) | row, row).unwrap();
    }

    let cases: [(u64, &[u64]); 4] = [
        (7, &[1, 3, 5, 7]),
        (3, &[2, 6]),
        (8, &[]),
        (LAST_USER, &[8, 9]), // upper bound is unbounded here
    ];
    for (user, rows) in cases {
        let range = prefix_range(user, 32);
        let forward: Vec<u64> = tree.range(range).map(|e| e.value).collect();
        assert_eq!(forward, rows);
        let mut backward: Vec<u64> = tree.range_backward(range).map(|e| e.value).collect();
        backward.reverse();
        assert_eq!(backward, rows);
    }
}

#[test]
fn a_cursor_survives_a_split_under_it_a_raw_position_does_not() {
    let mut tree = build_canonical();
    let mut pair = Pair::new();

    assert_eq!(pair.seek(&tree, Seek::Ge(10)), Some(10));
    assert_eq!(pair.next(&tree), Some(12)); // leaf #1 = (10 12), index 1
    let stale = pair.link.pos.clone();

    let splits_before = tree.base.stats.leaf_splits;
    for k in [11, 13, 14] {
        tree.put(k, k * 100).unwrap();
    }
    assert_eq!(tree.base.stats.leaf_splits, splits_before + 1);
    tree.validate().unwrap();

    // Leaf #1 is now (10 11): the old (leaf, index) names a different entry,
    // and stepping from it returns 12 again. This is the bug that the
    // version check prevents.
    let mut raw = stale;
    let mut ignored = Stats::default();
    assert_eq!(raw.entry(&tree.base).key, 11);
    assert_eq!(raw.next(&tree.base, &mut ignored).unwrap().key, 12);

    // The real cursors re-seek by key and carry on in order.
    assert_eq!(pair.entry(&tree), Some(12));
    for k in [13, 14, 15, 17] {
        assert_eq!(pair.next(&tree), Some(k));
    }
    assert_eq!(pair.link.stats.reseeks, 1); // once; then the position is fresh again
    assert_eq!(pair.stack.stats.reseeks, 1);
}

#[test]
fn the_entry_under_the_cursor_is_deleted_entry_is_none_next_and_prev_continue_from_its_key() {
    let mut tree = build_canonical();
    let mut pair = Pair::new();

    assert_eq!(pair.seek(&tree, Seek::Ge(12)), Some(12));
    tree.delete(12);
    assert_eq!(pair.entry(&tree), None);
    assert_eq!(pair.link.state, State::On(12)); // the key is still the position
    assert_eq!(pair.next(&tree), Some(15));

    assert_eq!(pair.seek(&tree, Seek::Ge(10)), Some(10));
    tree.delete(10);
    assert_eq!(pair.prev(&tree), Some(7));

    // Deleted and inserted again before the cursor looks: it is simply there.
    assert_eq!(pair.seek(&tree, Seek::Ge(17)), Some(17));
    tree.delete(17);
    tree.put(17, 1).unwrap();
    assert_eq!(pair.entry(&tree), Some(17));
    assert_eq!(pair.link.entry(&tree).unwrap().value, 1);
}

#[test]
fn an_overwrite_does_not_invalidate_a_cursor_and_is_visible_through_it() {
    let mut tree = build_canonical();
    let mut pair = Pair::new();

    assert_eq!(pair.seek(&tree, Seek::Ge(12)), Some(12));
    let version = tree.version;
    assert_eq!(tree.put(12, 77), Ok(Some(1200)));
    assert_eq!(tree.version, version);
    assert_eq!(pair.link.entry(&tree).unwrap().value, 77);
    assert_eq!(pair.stack.entry(&tree).unwrap().value, 77);
    assert_eq!(pair.link.stats.reseeks, 0);

    // Deleting an absent key changes nothing either.
    assert_eq!(tree.delete(13), None);
    assert_eq!(tree.version, version);
}

fn delete_everything_while_scanning<P: Position>(pos: P) {
    let mut tree = build_canonical();
    let mut scan = Scan::new(Cursor::new(pos), .., Direction::Forward);
    let mut n = 0;
    while let Some(e) = scan.next(&tree) {
        assert_eq!(e.key, SORTED[n]);
        assert_eq!(tree.delete(e.key), Some(e.value)); // delete what was just returned
        n += 1;
    }
    assert_eq!(n, SORTED.len());
    assert!(tree.is_empty());
    tree.validate().unwrap();
}

#[test]
fn delete_while_scanning_every_entry_is_returned_once() {
    delete_everything_while_scanning(LinkPosition::new());
    delete_everything_while_scanning(StackPosition::new());
}

#[test]
fn insert_while_scanning_keys_behind_the_cursor_are_not_seen_keys_ahead_are() {
    let mut tree = build_canonical();

    // `tree.range(5..=20)` would borrow the tree until the scan is dropped
    // and the puts below would not compile. A `Scan` borrows nothing.
    let mut scan = Scan::new(Cursor::new(LinkPosition::new()), 5..=20, Direction::Forward);
    assert_eq!(scan.next(&tree).unwrap().key, 5);
    assert_eq!(scan.next(&tree).unwrap().key, 6);
    tree.put(4, 0).unwrap(); // outside the range
    tree.put(5, 0).unwrap(); // overwrite behind the cursor
    tree.put(2, 0).unwrap(); // behind
    tree.put(8, 0).unwrap(); // ahead: will be returned
    tree.put(19, 0).unwrap(); // ahead
    tree.put(21, 0).unwrap(); // ahead but outside the range
    for k in [7, 8, 10, 12, 15, 17, 19, 20] {
        assert_eq!(scan.next(&tree).unwrap().key, k);
    }
    assert_eq!(scan.next(&tree), None);
}

#[test]
fn a_cursor_past_the_end_stays_there_a_cursor_on_the_last_entry_sees_later_inserts() {
    let mut tree = build_canonical();
    let mut on_last = Pair::new();
    let mut past_end = Pair::new();

    assert_eq!(on_last.seek(&tree, Seek::Last), Some(30));
    assert_eq!(past_end.seek(&tree, Seek::Last), Some(30));
    assert_eq!(past_end.next(&tree), None); // now AfterLast: no saved key
    tree.put(40, 4000).unwrap();
    // "On 30" continues with the first key > 30. "After the last entry" is
    // a position of its own, and an entry appended later is in front of it.
    assert_eq!(on_last.next(&tree), Some(40));
    assert_eq!(past_end.next(&tree), None);
    assert_eq!(past_end.link.state, State::AfterLast);
    assert_eq!(past_end.prev(&tree), Some(40));

    // The mirror image at the front.
    assert_eq!(on_last.seek(&tree, Seek::First), Some(1));
    assert_eq!(past_end.seek(&tree, Seek::First), Some(1));
    assert_eq!(past_end.prev(&tree), None);
    tree.put(0, 0).unwrap();
    assert_eq!(on_last.prev(&tree), Some(0));
    assert_eq!(past_end.prev(&tree), None);
    assert_eq!(past_end.stack.state, State::BeforeFirst);
    assert_eq!(past_end.next(&tree), Some(0));
}

#[test]
fn handles_are_reused_the_tree_is_emptied_and_refilled_under_a_cursor() {
    let mut tree = build_canonical();
    let mut pair = Pair::new();

    assert_eq!(pair.seek(&tree, Seek::Ge(12)), Some(12));
    for k in SORTED {
        tree.delete(k);
    }
    assert_eq!(tree.base.nodes.live_count(), 0); // every node was freed
    assert_eq!(pair.entry(&tree), None);

    // New nodes take the freed slots, so the cursor's old handles now name
    // unrelated nodes. Only the saved key 12 is still meaningful.
    for k in [40, 2, 13, 11, 50, 9] {
        tree.put(k, k).unwrap();
    }
    tree.validate().unwrap();
    assert_eq!(pair.next(&tree), Some(13));
    assert_eq!(pair.prev(&tree), Some(11));
    assert_eq!(pair.prev(&tree), Some(9));
}

#[test]
fn scratch_buffers_after_the_first_scan_later_scans_reuse_the_same_memory() {
    let tree = build_canonical();

    // First scan: the frame buffer and the result list are allocated.
    let mut first = Scan::new(Cursor::new(StackPosition::new()), .., Direction::Forward);
    let mut rows = Vec::new();
    first.collect_into(&tree, &mut rows);
    assert_eq!(rows.len(), SORTED.len());
    let mut frames = first.cursor.pos.into_buffer();
    let (frames_at, frames_capacity) = (frames.as_ptr(), frames.capacity());
    let (rows_at, rows_capacity) = (rows.as_ptr(), rows.capacity());

    // Later scans: same addresses, same capacities, so nothing was allocated
    // (Rust has no allocation counter to ask without a global allocator).
    for i in 0..100u64 {
        let direction = if i % 2 == 0 {
            Direction::Forward
        } else {
            Direction::Backward
        };
        let mut scan = Scan::new(
            Cursor::new(StackPosition::with_buffer(frames)),
            (i % 30)..,
            direction,
        );
        scan.collect_into(&tree, &mut rows);
        assert!(rows.len() <= SORTED.len());
        frames = scan.cursor.pos.into_buffer();
        assert_eq!(
            (frames.as_ptr(), frames.capacity()),
            (frames_at, frames_capacity)
        );
        assert_eq!((rows.as_ptr(), rows.capacity()), (rows_at, rows_capacity));
    }
}

#[test]
fn a_cloned_stack_cursor_keeps_the_reserved_capacity_and_its_own_path() {
    let mut tree = build_canonical();
    let mut original = StackCursor::new(StackPosition::new());
    assert_eq!(original.seek(&tree, Seek::Ge(12)).map(|e| e.key), Some(12));

    // The clone is a second, independent cursor on the same entry.
    let mut copy = original.clone();
    assert_eq!(copy.pos.path(), original.pos.path());
    assert_eq!(copy.next(&tree).map(|e| e.key), Some(15));
    assert_eq!(original.entry(&tree).map(|e| e.key), Some(12));

    // Make the tree taller, so the clone's re-seek needs more frames than
    // it held when it was cloned. Its buffer must not move or grow.
    let (depth, frames_at) = (copy.pos.path().len(), copy.pos.path().as_ptr());
    for k in 100..400 {
        tree.put(k, k).unwrap();
    }
    assert_eq!(copy.next(&tree).map(|e| e.key), Some(17));
    assert!(copy.pos.path().len() > depth);
    assert_eq!(copy.pos.path().as_ptr(), frames_at);
    assert_eq!(copy.stats.reseeks, 1);
    let buffer = copy.pos.into_buffer();
    assert_eq!(buffer.capacity(), original.pos.into_buffer().capacity());
    assert!(buffer.capacity() >= MAX_DEPTH);
}

#[test]
fn node_budget_exhausted_in_put_tree_version_and_cursors_are_unchanged() {
    // Rust's stand-in for Zig's allocation failure (chapter 07): the tree
    // may hold 8 nodes, which is exactly what the canonical keys need.
    let mut tree = Tree::with_node_budget(4, 8);
    for k in CANONICAL {
        tree.put(k, k * 100).unwrap();
    }
    let mut pair = Pair::new();
    assert_eq!(pair.seek(&tree, Seek::Ge(12)), Some(12));
    let version = tree.version;
    let count = tree.len();

    assert_eq!(tree.put(999, 1), Err(OutOfNodes));
    assert_eq!(tree.version, version);
    assert_eq!(tree.len(), count);
    tree.validate().unwrap();
    assert_eq!(pair.next(&tree), Some(15));
    assert_eq!(pair.link.stats.reseeks, 0); // no re-seek was needed
}

#[test]
fn model_random_operations_with_cursors_stepping_in_between_against_the_oracle() {
    for order in [3, 4, 5, 6, 7, 8, 16] {
        for seed in [1, 2, 3] {
            let r = model::run(model::Config {
                order,
                seed,
                count: 6000,
                key_space: 200,
            });
            assert_eq!(r.mismatches, 0);
            assert!(r.scans > 300 && r.cursor_steps > 4000);
            // The re-seek rule is shared code: both designs re-seek equally often.
            assert_eq!(r.link.reseeks, r.stack.reseeks);
            assert!(r.link.reseeks > 500);
        }
    }
    // A tiny key space empties the tree again and again.
    let small = model::run(model::Config {
        order: 3,
        seed: 9,
        count: 6000,
        key_space: 8,
    });
    assert_eq!(small.mismatches, 0);
}

#[test]
fn model_the_expected_side_sees_every_oracle_entry_including_the_key_u64_max() {
    let mut oracle = crate::ops::Oracle::new();
    for k in [MAX, 0, 7] {
        oracle.put(k, k);
    }
    // The half-open range of the oracle cannot name the last key ...
    assert_eq!(oracle.range(0, MAX).len(), 2);
    // ... so the model adds it.
    let all = model::all_entries(&oracle);
    assert_eq!(all.len(), 3);
    assert_eq!(all[0].key, 0);
    assert_eq!(all[2].key, MAX);
}
