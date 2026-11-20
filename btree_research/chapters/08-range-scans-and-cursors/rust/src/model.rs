//! Seeded model run: random puts, deletes, gets and range scans against the
//! sorted-array oracle from `common/`, with two long-lived cursors (one of
//! each design) that take a step between the operations. The tree therefore
//! changes under those cursors all the time, and every answer they give is
//! checked against what the oracle says the answer must be.
//!
//! Used by the tests (which demand zero mismatches) and by the demo program
//! (which prints the counts).

use crate::base_node::Entry;
use crate::bounds::{Bound, Direction, contains};
use crate::cursor::{Cursor, Seek, State, Stats};
use crate::link_cursor::{LinkCursor, LinkPosition};
use crate::ops::{self, Op, OpStream, Oracle, Weights};
use crate::prng::SplitMix64;
use crate::scan::Scan;
use crate::stack_cursor::{Frame, StackCursor, StackPosition};
use crate::tree::Tree;

#[derive(Debug, Clone, Copy)]
pub struct Config {
    pub order: usize,
    pub seed: u64,
    pub count: u64,
    pub key_space: u64,
}

#[derive(Debug, Clone, Copy, Default)]
pub struct Report {
    pub keys: usize,
    pub height: usize,
    /// Range scans compared with the oracle (each one by both cursors).
    pub scans: usize,
    /// Steps taken by the two long-lived cursors.
    pub cursor_steps: usize,
    pub link: Stats,
    pub stack: Stats,
    pub mismatches: usize,
}

/// Memory of one range scan, reused by the next: the stack cursor's frames
/// and the two result lists. After the first few scans nothing is allocated
/// any more (Zig: one arena, `reset(.retain_capacity)` after each scan).
#[derive(Default)]
struct Scratch {
    frames: Vec<Frame>,
    from_link: Vec<Entry>,
    from_stack: Vec<Entry>,
}

pub fn run(config: Config) -> Report {
    let mut tree = Tree::new(config.order);
    let mut oracle = Oracle::new();
    let stream = OpStream::new(ops::Config {
        seed: config.seed,
        count: config.count,
        key_space: config.key_space,
        weights: Weights::default(),
    });
    // A second generator for the choices the op stream does not make.
    let mut rng = SplitMix64::new(config.seed ^ 0xC0FFEE);
    let mut scratch = Scratch::default();

    // The long-lived cursors own their memory for the whole run.
    let mut link: LinkCursor = Cursor::new(LinkPosition::new());
    let mut stack: StackCursor = Cursor::new(StackPosition::new());
    let mut expected_state = State::BeforeFirst;
    let mut report = Report::default();
    const NO_BUDGET: &str = "no node budget set";

    for op in stream {
        match op {
            Op::Put { key, value } => {
                if tree.put(key, value).expect(NO_BUDGET) != oracle.put(key, value) {
                    report.mismatches += 1;
                }
            }
            Op::Delete { key } => {
                if tree.delete(key) != oracle.delete(key) {
                    report.mismatches += 1;
                }
            }
            Op::Get { key } => {
                if tree.get(key) != oracle.get(key) {
                    report.mismatches += 1;
                }
            }
            Op::Range { lo, hi } => {
                let mut lo = random_bound(&mut rng, lo);
                let mut hi = random_bound(&mut rng, hi);
                if rng.chance(1, 8) {
                    std::mem::swap(&mut lo, &mut hi); // inverted: must be empty
                }
                let direction = if rng.chance(1, 2) {
                    Direction::Forward
                } else {
                    Direction::Backward
                };
                report.mismatches += check_scan(&mut scratch, &tree, &oracle, lo, hi, direction);
                report.scans += 1;
            }
        }
        // One step of the long-lived cursors, whatever just happened.
        let all = oracle.range(0, u64::MAX);
        let action = rng.below(8);
        let expected: Option<ops::Entry>;
        let got_link: Option<Entry>;
        let got_stack: Option<Entry>;
        match action {
            0 => {
                let target = random_seek(&mut rng, config.key_space);
                expected = expected_seek(all, target);
                expected_state = match (expected, target) {
                    (Some(e), _) => State::On(e.key),
                    (None, Seek::First | Seek::Ge(_) | Seek::Gt(_)) => State::AfterLast,
                    (None, Seek::Last | Seek::Le(_) | Seek::Lt(_)) => State::BeforeFirst,
                };
                got_link = link.seek(&tree, target);
                got_stack = stack.seek(&tree, target);
            }
            1..=3 => {
                expected = match expected_state {
                    State::AfterLast => None,
                    State::BeforeFirst => expected_seek(all, Seek::First),
                    State::On(k) => expected_seek(all, Seek::Gt(k)),
                };
                expected_state = expected.map_or(State::AfterLast, |e| State::On(e.key));
                got_link = link.next(&tree);
                got_stack = stack.next(&tree);
            }
            4 | 5 => {
                expected = match expected_state {
                    State::BeforeFirst => None,
                    State::AfterLast => expected_seek(all, Seek::Last),
                    State::On(k) => expected_seek(all, Seek::Lt(k)),
                };
                expected_state = expected.map_or(State::BeforeFirst, |e| State::On(e.key));
                got_link = link.prev(&tree);
                got_stack = stack.prev(&tree);
            }
            6 => {
                expected = match expected_state {
                    State::BeforeFirst | State::AfterLast => None,
                    State::On(k) => oracle.get(k).map(|v| ops::Entry { key: k, value: v }),
                };
                got_link = link.entry(&tree);
                got_stack = stack.entry(&tree);
            }
            _ => continue, // 7: no cursor step this time
        }
        report.cursor_steps += 1;
        if !same(expected, got_link) {
            report.mismatches += 1;
        }
        if !same(expected, got_stack) {
            report.mismatches += 1;
        }
        if link.state != expected_state || stack.state != expected_state {
            report.mismatches += 1;
        }
    }
    tree.validate().expect("valid tree");
    report.keys = tree.len();
    report.height = tree.base.height;
    report.link = link.stats;
    report.stack = stack.stats;
    report
}

/// Runs the scan with both cursors and counts differences from the oracle
/// filtered by the definition of a range (`bounds::contains`).
fn check_scan(
    scratch: &mut Scratch,
    tree: &Tree,
    oracle: &Oracle,
    lo: Bound<u64>,
    hi: Bound<u64>,
    direction: Direction,
) -> usize {
    let mut by_link = Scan::new(Cursor::new(LinkPosition::new()), (lo, hi), direction);
    let frames = std::mem::take(&mut scratch.frames);
    let mut by_stack = Scan::new(Cursor::new(StackPosition::with_buffer(frames)), (lo, hi), direction);
    by_link.collect_into(tree, &mut scratch.from_link);
    by_stack.collect_into(tree, &mut scratch.from_stack);
    scratch.frames = by_stack.cursor.pos.into_buffer(); // hand the memory back

    let (from_link, from_stack) = (&scratch.from_link, &scratch.from_stack);
    let mut mismatches = 0;
    let mut n = 0;
    let all = oracle.range(0, u64::MAX);
    for i in 0..all.len() {
        let e = match direction {
            Direction::Forward => all[i],
            Direction::Backward => all[all.len() - 1 - i],
        };
        if !contains(lo, hi, e.key) {
            continue;
        }
        if !same(Some(e), from_link.get(n).copied()) {
            mismatches += 1;
        }
        if !same(Some(e), from_stack.get(n).copied()) {
            mismatches += 1;
        }
        n += 1;
    }
    if from_link.len() != n {
        mismatches += 1;
    }
    if from_stack.len() != n {
        mismatches += 1;
    }
    mismatches
}

fn same(expected: Option<ops::Entry>, got: Option<Entry>) -> bool {
    match (expected, got) {
        (None, None) => true,
        (Some(e), Some(g)) => e.key == g.key && e.value == g.value,
        _ => false,
    }
}

fn random_bound(rng: &mut SplitMix64, key: u64) -> Bound<u64> {
    match rng.below(3) {
        0 => Bound::Unbounded,
        1 => Bound::Included(key),
        _ => Bound::Excluded(key),
    }
}

fn random_seek(rng: &mut SplitMix64, key_space: u64) -> Seek {
    let kind = rng.below(6);
    let key = rng.below(key_space);
    match kind {
        0 => Seek::First,
        1 => Seek::Last,
        2 => Seek::Ge(key),
        3 => Seek::Gt(key),
        4 => Seek::Le(key),
        _ => Seek::Lt(key),
    }
}

/// What a seek must return, by counting in the sorted array.
fn expected_seek(all: &[ops::Entry], target: Seek) -> Option<ops::Entry> {
    // Number of entries in front of the landing point.
    let before = all
        .iter()
        .filter(|e| match target {
            Seek::First => false,
            Seek::Last => true,
            Seek::Ge(k) | Seek::Lt(k) => e.key < k,
            Seek::Gt(k) | Seek::Le(k) => e.key <= k,
        })
        .count();
    match target {
        // Forward seeks: the first entry that is not in front.
        Seek::First | Seek::Ge(_) | Seek::Gt(_) => all.get(before).copied(),
        // Backward seeks: the last entry that is.
        Seek::Last | Seek::Le(_) | Seek::Lt(_) => before.checked_sub(1).map(|i| all[i]),
    }
}
