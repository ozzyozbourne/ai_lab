//! Chapter 14: the experiment. Four insert workloads, four split policies,
//! and a text report of what each policy did to the pages.
//!
//! The report is built as a `String`, so `main` can print it and the test can
//! compare it with expected_output.txt.

use std::fmt::Write;

use crate::pages::{ALL_POLICIES, Fill, Tree};
use crate::prng::SplitMix64;
use crate::split::{self, HAND_CAPACITY, HAND_ITEMS, HAND_NEW_INDEX, PageInfo, Policy};

pub const PAGE_CAPACITY: u32 = 4096;

/// The order in which keys arrive. The row id (tid) of the i-th insert is
/// always i: rows are numbered in arrival order, like heap TIDs mostly are.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Workload {
    /// key = i: a sequence, a timestamp, an auto-increment id.
    Ascending,
    /// keys 0..n in shuffled order: every page is hit equally often.
    Random,
    /// n/8 distinct keys picked at random: short runs of equal keys.
    DupGroups,
    /// n/1000 + 2 distinct keys: each key fills many pages.
    DupHeavy,
}

impl Workload {
    pub fn label(self) -> &'static str {
        match self {
            Workload::Ascending => "ascending",
            Workload::Random => "random",
            Workload::DupGroups => "dup-groups",
            Workload::DupHeavy => "dup-heavy",
        }
    }
}

pub const ALL_WORKLOADS: [Workload; 4] = [
    Workload::Ascending,
    Workload::Random,
    Workload::DupGroups,
    Workload::DupHeavy,
];

/// "half", "fill-90", "rightmost-90", "adaptive-90".
pub fn policy_label(policy: Policy) -> String {
    match policy {
        Policy::Half => "half".to_string(),
        Policy::Fill(ff) => format!("fill-{ff}"),
        Policy::Rightmost(ff) => format!("rightmost-{ff}"),
        Policy::Adaptive(ff) => format!("adaptive-{ff}"),
    }
}

/// Insert `n` cells of 40 to 120 bytes into a fresh tree. One PRNG, seeded
/// with `seed`, drives keys and sizes in a fixed draw order (shuffle first if
/// any, then per insert: key if any, then size), so the Zig version and the
/// JavaScript model replay exactly the same inserts.
pub fn run_workload(workload: Workload, policy: Policy, n: u64, seed: u64) -> Tree {
    let mut tree = Tree::new(PAGE_CAPACITY, policy);
    let mut rng = SplitMix64::new(seed);

    let mut order: Vec<u64> = Vec::new();
    if workload == Workload::Random {
        order = (0..n).collect();
        rng.shuffle(&mut order);
    }

    for i in 0..n {
        let key = match workload {
            Workload::Ascending => i,
            Workload::Random => order[i as usize],
            Workload::DupGroups => rng.below(n / 8),
            Workload::DupHeavy => rng.below(n / 1000 + 2),
        };
        let size = rng.range(40, 121) as u16;
        tree.put(key, i, size)
            .expect("no page budget is set and sizes are legal");
    }
    tree
}

// `write!` into a String cannot fail, hence the unwraps in this file.

fn write_percent(w: &mut String, permille: u64) {
    write!(w, "{:>3}.{}%", permille / 10, permille % 10).unwrap();
}

/// Part 1: the hand example of the README, one overfull page of capacity 100.
fn write_hand_example(w: &mut String) {
    let items = &HAND_ITEMS;
    let cap = HAND_CAPACITY;

    writeln!(w, "== 1. One split by hand (page capacity {cap} bytes) ==").unwrap();
    w.push_str("imaginary page, (key,tid):bytes, new cell marked *\n ");
    for (i, c) in items.iter().enumerate() {
        let mark = if i == HAND_NEW_INDEX { "*" } else { "" };
        write!(w, " {mark}({},{}):{}", c.key, c.tid, c.size).unwrap();
    }
    w.push_str("\n\ncandidate split points (cut before index s)\n");
    w.push_str("  s  left  right  delta 50:50  delta 90:10  separator\n");
    let mut cands = Vec::new();
    split::candidates(&mut cands, items, cap);
    for &c in &cands {
        let fr = items[c.first_right as usize];
        write!(
            w,
            "{:>3}  {:>4}  {:>5}  {:>11}  {:>11}  ",
            c.first_right,
            c.left_bytes,
            c.right_bytes,
            split::delta_of(c, cap, None),
            split::delta_of(c, cap, Some(90)),
        )
        .unwrap();
        if split::penalty_of(items, c) == 1 {
            writeln!(w, "({})      8 bytes", fr.key).unwrap();
        } else {
            writeln!(w, "({},{})   16 bytes", fr.key, fr.tid).unwrap();
        }
    }

    w.push_str("\nchoice when the page is NOT the rightmost page (upper bound 40)\n");
    write_hand_choices(w, &mut cands, Some(40));
    w.push_str("\nchoice when the page IS the rightmost page\n");
    write_hand_choices(w, &mut cands, None);
}

fn write_hand_choices(w: &mut String, scratch: &mut Vec<split::Candidate>, upper_key: Option<u64>) {
    for policy in ALL_POLICIES {
        let page = PageInfo {
            capacity: HAND_CAPACITY,
            upper_key,
        };
        let c = split::choose_split(scratch, &HAND_ITEMS, HAND_NEW_INDEX, page, policy);
        writeln!(
            w,
            "  {:<13} s={}  left {:>2}  right {:>2}  separator {:>2} bytes  {}",
            policy_label(policy),
            c.first_right,
            c.left_bytes,
            c.right_bytes,
            8 * c.penalty,
            c.strategy.label(),
        )
        .unwrap();
    }
}

/// Part 2: every workload under every policy, at full page size.
fn write_experiment(w: &mut String, n: u64, seed: u64) {
    writeln!(
        w,
        "\n== 2. {n} inserts of 40..120 byte cells, page capacity {PAGE_CAPACITY} =="
    )
    .unwrap();
    for workload in ALL_WORKLOADS {
        let mut fills: Vec<Fill> = Vec::new();

        writeln!(w, "\nworkload {}", workload.label()).unwrap();
        w.push_str("  policy         pages  avg fill  min fill  splits  default/manydup/single  tid seps  sep bytes\n");
        for policy in ALL_POLICIES {
            let tree = run_workload(workload, policy, n, seed);
            tree.validate().expect("valid tree");
            let f = tree.fill();
            fills.push(f);
            let s = tree.stats.by_strategy;
            write!(w, "  {:<13}  {:>5}    ", policy_label(policy), f.pages).unwrap();
            write_percent(w, f.avg_permille(PAGE_CAPACITY));
            w.push_str("    ");
            write_percent(w, u64::from(f.min_used) * 1000 / u64::from(PAGE_CAPACITY));
            writeln!(
                w,
                "  {:>6}  {:>7}/{:>7}/{:>6}  {:>8}  {:>9}",
                tree.stats.splits, s[0], s[1], s[2], f.tid_seps, f.sep_bytes,
            )
            .unwrap();
        }

        w.push_str("  pages by fill    0-9  10-  20-  30-  40-  50-  60-  70-  80-  90-100%\n");
        for (policy, f) in ALL_POLICIES.into_iter().zip(&fills) {
            write!(w, "  {:<13}", policy_label(policy)).unwrap();
            for count in f.histogram {
                write!(w, "  {count:>3}").unwrap();
            }
            w.push('\n');
        }
    }
}

/// Part 3: a small run whose complete final state fits on a few lines. The
/// visualization replays it with its own JavaScript model and compares.
pub const SCENARIO_N: u64 = 300;
pub const SCENARIO_SEED: u64 = 14;

fn write_scenario(w: &mut String) {
    writeln!(
        w,
        "\n== 3. Fixed scenario: {SCENARIO_N} inserts, seed {SCENARIO_SEED}, bytes used per page in key order =="
    )
    .unwrap();
    for workload in ALL_WORKLOADS {
        writeln!(w, "workload {}", workload.label()).unwrap();
        for policy in ALL_POLICIES {
            let tree = run_workload(workload, policy, SCENARIO_N, SCENARIO_SEED);
            tree.validate().expect("valid tree");
            write!(w, "  {:<13}", policy_label(policy)).unwrap();
            for entry in &tree.dir {
                write!(w, " {}", tree.leaves[entry.leaf as usize].used).unwrap();
            }
            w.push('\n');
        }
    }
}

pub const EXPERIMENT_N: u64 = 20_000;
pub const EXPERIMENT_SEED: u64 = 2014;

pub fn write_report() -> String {
    let mut w = String::new();
    write_hand_example(&mut w);
    write_experiment(&mut w, EXPERIMENT_N, EXPERIMENT_SEED);
    write_scenario(&mut w);
    w
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_report_is_exactly_expected_output_txt() {
        assert_eq!(write_report(), include_str!("../../expected_output.txt"));
    }

    #[test]
    fn workloads_are_deterministic_and_keep_every_cell() {
        for workload in ALL_WORKLOADS {
            let a = run_workload(workload, Policy::Adaptive(90), 500, 3);
            let b = run_workload(workload, Policy::Adaptive(90), 500, 3);
            a.validate().unwrap();
            assert_eq!(a.len, 500);
            assert_eq!(a.fill(), b.fill());
            // The policy changes where cells live, never which cells exist.
            let c = run_workload(workload, Policy::Half, 500, 3);
            assert_eq!(a.fill().used_bytes, c.fill().used_bytes);
            assert_eq!(a.range(0, 500), c.range(0, 500));
        }
    }

    #[test]
    fn the_policies_rank_as_the_chapter_claims() {
        let fill_of = |workload, policy| run_workload(workload, policy, 4000, 9).fill();
        use Policy::{Adaptive, Fill, Half, Rightmost};
        use Workload::{Ascending, DupGroups, DupHeavy, Random};
        // Appends: the rightmost rule saves pages, and adaptive inherits it.
        assert!(fill_of(Ascending, Rightmost(90)).pages < fill_of(Ascending, Half).pages);
        assert_eq!(
            fill_of(Ascending, Rightmost(90)).pages,
            fill_of(Ascending, Adaptive(90)).pages
        );
        // Random inserts: packing the left page everywhere costs pages.
        assert!(fill_of(Random, Fill(90)).pages > fill_of(Random, Half).pages);
        // Duplicates: adaptive needs fewer separators that carry a tid.
        assert!(fill_of(DupGroups, Adaptive(90)).tid_seps < fill_of(DupGroups, Half).tid_seps);
        assert!(fill_of(DupHeavy, Adaptive(90)).pages < fill_of(DupHeavy, Half).pages);
    }
}
