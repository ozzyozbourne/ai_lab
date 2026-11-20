//! Chapter 14: WHERE to cut a full page.
//!
//! This file is a pure decision procedure. It is handed the cells of a page
//! that is too full, with the incoming cell already placed at its sorted
//! position ("the imaginary page"), and answers one question: which gap
//! between two neighbouring cells becomes the boundary between the left and
//! the right page? It moves no cells; `pages.rs` acts on the answer.
//!
//! The shape follows PostgreSQL's postgres/src/backend/access/nbtree/nbtsplitloc.c:
//!   1. list every legal split point with the free space it leaves  (_bt_recsplitloc)
//!   2. give each a "delta" = distance from the space target, sort   (_bt_deltasortsplits)
//!   3. keep the candidates close enough to the best one             (_bt_defaultinterval)
//!   4. among those, take the one with the cheapest separator        (_bt_bestsplitloc)
//!   5. fall back to other strategies when duplicates get in the way (_bt_strategy)

/// One entry of a leaf page. Only its ordering and its size matter here.
/// `tid` is the row id that makes equal keys distinct (chapter 07): cells are
/// ordered by (key, tid), so there are no true duplicates inside the tree.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Cell {
    pub key: u64,
    pub tid: u64,
    /// Bytes this cell occupies in the page, slot entry included.
    pub size: u16,
}

pub fn cell_less(a: Cell, b: Cell) -> bool {
    (a.key, a.tid) < (b.key, b.tid)
}

/// The split policy is a value, not a trait object: an enum that
/// `choose_split` matches on. The payload is a fill factor in percent, so it
/// must be 0..=100 (`is_valid`); `Tree::new` and `delta_of` assert that.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Policy {
    /// Textbook: equalize the bytes on both sides, always.
    Half,
    /// Naive fill factor: leave the LEFT page `ff`% full on every split.
    Fill(u8),
    /// `Half`, except that the rightmost page of the level is cut so that the
    /// left page stays `ff`% full (the append optimisation).
    Rightmost(u8),
    /// `Rightmost` plus the duplicate-aware part of nbtsplitloc.c: split
    /// interval, separator penalty, "many duplicates" and "single value".
    Adaptive(u8),
}

impl Policy {
    /// Is the fill factor a percentage? Anything above 100 has no meaning
    /// ("the left page stays 150% full") and would make `100 - ff` in
    /// `delta_of` overflow.
    pub fn is_valid(self) -> bool {
        match self {
            Policy::Half => true,
            Policy::Fill(ff) | Policy::Rightmost(ff) | Policy::Adaptive(ff) => ff <= 100,
        }
    }
}

/// Which of the three nbtsplitloc.c strategies decided a split
/// (FindSplitStrat, nbtsplitloc.c:21-27). Only `Adaptive` leaves `Default`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Strategy {
    Default,
    ManyDuplicates,
    SingleValue,
}

impl Strategy {
    pub fn label(self) -> &'static str {
        match self {
            Strategy::Default => "default",
            Strategy::ManyDuplicates => "many_duplicates",
            Strategy::SingleValue => "single_value",
        }
    }
}

/// Left-page fill used by the single value strategy
/// (BTREE_SINGLEVAL_FILLFACTOR, postgres/src/include/access/nbtree.h:203).
pub const SINGLE_VALUE_FILL: u8 = 96;

/// A legal split point. `first_right` indexes the imaginary page: cells
/// [0, first_right) go left, cells [first_right, n) go right.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Candidate {
    pub first_right: u32,
    pub left_bytes: u32,
    pub right_bytes: u32,
    /// Distance from the space target; smaller is better. Set by `delta_sort`.
    pub delta: u64,
}

/// What the policy needs to know about the page besides its cells.
#[derive(Debug, Clone, Copy)]
pub struct PageInfo {
    pub capacity: u32,
    /// Key of the separator that bounds this page from above, or None when
    /// the page is the rightmost one of its level (upper bound = +infinity).
    pub upper_key: Option<u64>,
}

impl PageInfo {
    pub fn is_rightmost(&self) -> bool {
        self.upper_key.is_none()
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Choice {
    pub first_right: u32,
    pub left_bytes: u32,
    pub right_bytes: u32,
    /// 1: the two cells around the cut have different keys, so the separator
    ///    can be the bare key. 2: equal keys, the separator must carry a tid.
    pub penalty: u8,
    pub strategy: Strategy,
    /// How many candidates were close enough to the space target to be
    /// compared by penalty (always 1 for the non-adaptive policies).
    pub interval: u32,
}

/// Step 1: every gap of the imaginary page whose two sides both fit in a
/// page, written into `out` (which is cleared first, keeping its buffer).
/// The result is in position order and the legal gaps are contiguous,
/// because left_bytes only grows and right_bytes only shrinks along the page.
pub fn candidates(out: &mut Vec<Candidate>, items: &[Cell], capacity: u32) {
    out.clear();
    let total: u32 = items.iter().map(|c| u32::from(c.size)).sum();
    let mut left = 0u32;
    for (i, c) in items[..items.len() - 1].iter().enumerate() {
        left += u32::from(c.size);
        let right = total - left;
        // Invariant of every page: used <= capacity. A gap that would break
        // it on either side is not a candidate at all.
        if left <= capacity && right <= capacity {
            out.push(Candidate {
                first_right: i as u32 + 1,
                left_bytes: left,
                right_bytes: right,
                delta: 0,
            });
        }
    }
}

/// The space target as a number. `fill == None` asks for equal free space on
/// both sides. Otherwise the left page should end up `fill`% full, which is
/// the same as saying left_free : right_free = (100 - fill) : fill.
/// nbtsplitloc.c:575-582 computes this with doubles; we scale by 100 and stay
/// in integers so that Zig and Rust agree bit for bit.
/// `fill` is a percentage; more than 100 is a programming error (asserted).
pub fn delta_of(c: Candidate, capacity: u32, fill: Option<u8>) -> u64 {
    assert!(fill.is_none_or(|ff| ff <= 100), "a fill factor is a percentage");
    let left_free = i64::from(capacity) - i64::from(c.left_bytes);
    let right_free = i64::from(capacity) - i64::from(c.right_bytes);
    let d = match fill {
        Some(ff) => i64::from(ff) * left_free - i64::from(100 - ff) * right_free,
        None => left_free - right_free,
    };
    d.unsigned_abs()
}

/// Step 2: best space balance first. Ties go to the leftmost gap, which makes
/// the order total and therefore identical in every implementation.
pub fn delta_sort(cands: &mut [Candidate], capacity: u32, fill: Option<u8>) {
    for c in cands.iter_mut() {
        c.delta = delta_of(*c, capacity, fill);
    }
    cands.sort_unstable_by_key(|c| (c.delta, c.first_right));
}

/// The price of cutting at `c`, measured by what the separator must contain.
/// With one key column this is nbtree's "number of attributes to keep"
/// (_bt_split_penalty, nbtsplitloc.c:1131-1154): 1 or 2.
pub fn penalty_of(items: &[Cell], c: Candidate) -> u8 {
    let last_left = items[c.first_right as usize - 1];
    let first_right = items[c.first_right as usize];
    if last_left.key != first_right.key {
        1
    } else {
        2
    }
}

/// Step 3: how many candidates at the front of the sorted array leave free
/// space within `tolerance` bytes of the best one (_bt_defaultinterval,
/// nbtsplitloc.c:876-921).
fn default_interval(cands: &[Candidate], tolerance: u32) -> u32 {
    let best = cands[0];
    for (i, c) in cands.iter().enumerate().skip(1) {
        // free = capacity - bytes on both sides, so comparing bytes is the
        // same as comparing free space.
        if c.left_bytes.abs_diff(best.left_bytes) > tolerance
            || c.right_bytes.abs_diff(best.right_bytes) > tolerance
        {
            return i as u32;
        }
    }
    cands.len() as u32
}

/// Index of the first (lowest delta) candidate with penalty 1, if any.
fn first_distinct(items: &[Cell], cands: &[Candidate]) -> Option<usize> {
    cands.iter().position(|&c| penalty_of(items, c) == 1)
}

/// Decide where to cut. `items` is the imaginary page: the old cells with the
/// new one already inserted at `new_index`, sorted by (key, tid).
///
/// `cands` is scratch space: its old contents are discarded and its buffer is
/// reused, which is this port's version of Zig's arena reset.
pub fn choose_split(
    cands: &mut Vec<Candidate>,
    items: &[Cell],
    new_index: usize,
    page: PageInfo,
    policy: Policy,
) -> Choice {
    candidates(cands, items, page.capacity);
    // pages.rs caps a cell at capacity / 4, which guarantees a legal gap.
    assert!(!cands.is_empty());

    // Remember the outermost legal gaps before sorting destroys page order
    // (nbtsplitloc.c:342-343). They tell us what the whole page looks like.
    let leftmost = cands[0];
    let rightmost = cands[cands.len() - 1];

    // Which space target? This is the entire difference between the first
    // three policies (compare nbtsplitloc.c:281-336).
    let fill = match policy {
        Policy::Half => None,
        Policy::Fill(ff) => Some(ff),
        Policy::Rightmost(ff) | Policy::Adaptive(ff) => page.is_rightmost().then_some(ff),
    };
    delta_sort(cands, page.capacity, fill);

    let mut pick = 0usize; // the space-optimal candidate
    let mut strategy = Strategy::Default;
    let mut interval = 1u32;

    if matches!(policy, Policy::Adaptive(_)) {
        // 5% of the bytes that were on the page before the new cell arrived
        // (LEAF_SPLIT_DISTANCE, nbtsplitloc.c:850).
        let old_bytes =
            leftmost.left_bytes + leftmost.right_bytes - u32::from(items[new_index].size);
        interval = default_interval(cands, old_bytes / 20);

        if let Some(i) = first_distinct(items, &cands[..interval as usize]) {
            // Default strategy: a slightly less balanced cut that falls
            // between two different keys beats a perfectly balanced one that
            // falls inside a run of equal keys.
            pick = i;
        } else if items[leftmost.first_right as usize - 1].key
            != items[rightmost.first_right as usize].key
        {
            // Many duplicates: nothing near the middle works, but the page
            // does hold more than one key. Look at ALL legal gaps and take
            // the best-balanced one at the edge of a duplicate group, however
            // lopsided (nbtsplitloc.c:376-388, 398-406).
            strategy = Strategy::ManyDuplicates;
            interval = cands.len() as u32;
            pick = first_distinct(items, cands).expect("the page holds two different keys");
        } else if page.upper_key != Some(items[new_index].key) {
            // Single value: the page is one long run of a single key, and the
            // upper bound shows that no page to the right holds this key
            // (None, the rightmost page, also lands here). New cells of this
            // key carry higher tids and will keep arriving at the right end,
            // so treat it like an append: pack the left page
            // (nbtsplitloc.c:407-417, 1017-1042).
            strategy = Strategy::SingleValue;
            delta_sort(cands, page.capacity, Some(SINGLE_VALUE_FILL));
            interval = 1;
        }
        // else: one single key, but more of it lives to the right, so this is
        // a random insert into the middle of the group. Keep the 50:50 cut.
    }

    let c = cands[pick];
    Choice {
        first_right: c.first_right,
        left_bytes: c.left_bytes,
        right_bytes: c.right_bytes,
        penalty: penalty_of(items, c),
        strategy,
        interval,
    }
}

/// The page of the README's hand example: capacity 100, 94 bytes used, and a
/// 12-byte cell (20, 5) arriving at index 5.
pub const HAND_CAPACITY: u32 = 100;
pub const HAND_NEW_INDEX: usize = 5;
pub const HAND_ITEMS: [Cell; 7] = [
    Cell {
        key: 10,
        tid: 1,
        size: 18,
    },
    Cell {
        key: 20,
        tid: 1,
        size: 14,
    },
    Cell {
        key: 20,
        tid: 2,
        size: 14,
    },
    Cell {
        key: 20,
        tid: 3,
        size: 14,
    },
    Cell {
        key: 20,
        tid: 4,
        size: 14,
    },
    Cell {
        key: 20,
        tid: 5,
        size: 12,
    },
    Cell {
        key: 30,
        tid: 1,
        size: 20,
    },
];

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    fn hand_choice(policy: Policy, upper_key: Option<u64>) -> Choice {
        let page = PageInfo {
            capacity: HAND_CAPACITY,
            upper_key,
        };
        choose_split(&mut Vec::new(), &HAND_ITEMS, HAND_NEW_INDEX, page, policy)
    }

    #[test]
    fn candidates_every_gap_of_the_hand_example_is_legal() {
        let mut cands = Vec::new();
        candidates(&mut cands, &HAND_ITEMS, HAND_CAPACITY);
        assert_eq!(cands.len(), 6);
        assert_eq!((cands[0].left_bytes, cands[0].right_bytes), (18, 88));
        assert_eq!((cands[5].left_bytes, cands[5].right_bytes), (86, 20));
    }

    #[test]
    fn candidates_gaps_that_overflow_one_side_are_dropped() {
        // 106 bytes in total and capacity 80: the left side must hold at least 26.
        let mut cands = Vec::new();
        candidates(&mut cands, &HAND_ITEMS, 80);
        assert_eq!(cands.len(), 4);
        assert_eq!(cands[0].first_right, 2);
        assert_eq!(cands[3].first_right, 5);
    }

    #[test]
    fn half_cuts_in_the_middle_inside_the_duplicates() {
        let c = hand_choice(Policy::Half, Some(40));
        assert_eq!(
            (c.first_right, c.left_bytes, c.right_bytes, c.penalty),
            (3, 46, 60, 2)
        );
    }

    #[test]
    fn fill_and_rightmost_differ_only_on_a_page_that_is_not_rightmost() {
        assert_eq!(hand_choice(Policy::Fill(90), Some(40)).first_right, 6);
        assert_eq!(hand_choice(Policy::Fill(90), None).first_right, 6);
        assert_eq!(hand_choice(Policy::Rightmost(90), Some(40)).first_right, 3); // behaves like half
        assert_eq!(hand_choice(Policy::Rightmost(90), None).first_right, 6);
    }

    #[test]
    fn adaptive_many_duplicates_moves_the_cut_to_the_edge_of_the_group() {
        let c = hand_choice(Policy::Adaptive(90), Some(40));
        assert_eq!(c.strategy, Strategy::ManyDuplicates);
        assert_eq!((c.first_right, c.penalty, c.interval), (6, 1, 6));
    }

    fn run_of(n: usize, key_of: impl Fn(usize) -> u64) -> Vec<Cell> {
        (0..n)
            .map(|i| Cell {
                key: key_of(i),
                tid: i as u64,
                size: 4,
            })
            .collect()
    }

    #[test]
    fn adaptive_default_strategy_trades_a_little_balance_for_a_short_separator() {
        // 26 cells of 4 bytes; the key changes between index 13 and 14. The
        // perfectly balanced cut (before 13) falls inside key 1. The tolerance is
        // 5% of 100 bytes, so the cuts before 12 and 14 are also acceptable, and
        // the one before 14 has two different keys around it.
        let items = run_of(26, |i| if i < 14 { 1 } else { 2 });
        let page = PageInfo {
            capacity: 100,
            upper_key: Some(9),
        };
        let mut cands = Vec::new();
        let half = choose_split(&mut cands, &items, 25, page, Policy::Half);
        let adaptive = choose_split(&mut cands, &items, 25, page, Policy::Adaptive(90));
        assert_eq!((half.first_right, half.penalty), (13, 2));
        assert_eq!((adaptive.first_right, adaptive.penalty), (14, 1));
        assert_eq!(adaptive.strategy, Strategy::Default);
        assert_eq!(adaptive.interval, 3); // gaps 13, 12 and 14
    }

    #[test]
    fn adaptive_single_value_packs_the_left_page_only_at_the_end_of_the_group() {
        let items = run_of(26, |_| 7);
        let mut cands = Vec::new();
        let policy = Policy::Adaptive(90);

        // Upper bound is another key: this is the last page holding key 7.
        let last = choose_split(
            &mut cands,
            &items,
            25,
            PageInfo {
                capacity: 100,
                upper_key: Some(8),
            },
            policy,
        );
        assert_eq!(last.strategy, Strategy::SingleValue);
        assert_eq!(last.left_bytes, 96);

        // Rightmost page of the level: same.
        let rightmost = choose_split(
            &mut cands,
            &items,
            25,
            PageInfo {
                capacity: 100,
                upper_key: None,
            },
            policy,
        );
        assert_eq!(rightmost.strategy, Strategy::SingleValue);

        // Upper bound is key 7 itself: more 7s live to the right, split 50:50.
        let middle = choose_split(
            &mut cands,
            &items,
            3,
            PageInfo {
                capacity: 100,
                upper_key: Some(7),
            },
            policy,
        );
        assert_eq!(middle.strategy, Strategy::Default);
        assert_eq!((middle.left_bytes, middle.penalty), (52, 2));
    }

    #[test]
    fn choose_split_reuses_the_scratch_buffer() {
        // The Rust counterpart of Zig's "OutOfMemory from the scratch
        // allocator" test: there is no fallible allocation to inject a
        // failure into, so check the property the scratch buffer exists for.
        let mut cands = Vec::new();
        let page = PageInfo {
            capacity: HAND_CAPACITY,
            upper_key: None,
        };
        choose_split(&mut cands, &HAND_ITEMS, HAND_NEW_INDEX, page, Policy::Half);
        let (ptr, cap) = (cands.as_ptr(), cands.capacity());
        choose_split(
            &mut cands,
            &HAND_ITEMS,
            HAND_NEW_INDEX,
            page,
            Policy::Adaptive(90),
        );
        assert_eq!((cands.as_ptr(), cands.capacity()), (ptr, cap));
    }
}
