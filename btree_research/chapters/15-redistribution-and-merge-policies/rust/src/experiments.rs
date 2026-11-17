//! The chapter's `run` program: a fixed hand-sized scenario, then the policy
//! comparisons. Everything is deterministic and printed with integers only,
//! so the Zig and Rust programs produce the same bytes.
//!
//! Twin of ../zig/src/experiments.zig.
use std::fmt::Write as _;

use crate::pages::{self, Cell, Config, MergePolicy, Stats, Tree};
use crate::prng::SplitMix64;

/// Print one redistribution: the cells of each page with the page totals.
fn print_strip(w: &mut String, label: &str, sizes: &[u32], ends: &[u32]) {
    write!(w, "  {label:<10}").unwrap();
    let mut first = 0;
    for (p, &end) in ends.iter().enumerate() {
        if p != 0 {
            w.push_str(" |");
        }
        let page = &sizes[first..end as usize];
        for s in page {
            write!(w, " {s}").unwrap();
        }
        write!(w, " ={}", page.iter().sum::<u32>()).unwrap();
        first = end as usize;
    }
    w.push('\n');
}

/// Part 1: `pack_left` and `even_out` on three hand-made sibling groups.
fn redistribution_by_hand(w: &mut String) {
    let cases: [(&str, &[u32], &[u32]); 3] = [
        (
            "redistribute: the middle page is overfull, its neighbours have room",
            &[20, 20, 20, 30, 20, 20, 20, 25, 25, 10, 10],
            &[3, 8, 11],
        ),
        (
            "split: three full pages and one cell too many",
            &[25, 25, 25, 25, 20, 20, 20, 20, 20, 15, 25, 25, 25, 25],
            &[4, 10, 14],
        ),
        ("merge: three pages that are mostly free", &[20, 15, 10, 25, 20, 30, 10], &[2, 4, 7]),
    ];
    w.push_str("== 1. Redistribution by hand (capacity 100) ==\n");
    let mut ends = Vec::new();
    for (name, sizes, old_ends) in cases {
        writeln!(w, "{name}").unwrap();
        print_strip(w, "before", sizes, old_ends);
        pages::pack_left(sizes, 100, &mut ends);
        print_strip(w, "pack left", sizes, &ends);
        pages::even_out(sizes, &mut ends);
        print_strip(w, "even out", sizes, &ends);
        writeln!(w, "  pages: {} in, {} out", old_ends.len(), ends.len()).unwrap();
    }
}

pub struct Step {
    pub text: &'static str,
    pub puts: &'static [Cell],
    pub deletes: &'static [u64],
}

const fn c(key: u64, size: u32) -> Cell {
    Cell { key, size }
}

/// The fixed scenario. The visualization replays exactly these steps and
/// checks its final picture against the one printed here.
pub const SCENARIO: [Step; 7] = [
    Step {
        text: "put 10 20 30 40 (25 bytes each): one full leaf",
        puts: &[c(10, 25), c(20, 25), c(30, 25), c(40, 25)],
        deletes: &[],
    },
    Step { text: "put 50: append fast path, nothing moves", puts: &[c(50, 25)], deletes: &[] },
    Step { text: "put 60 70 80: the right-most leaf fills up", puts: &[c(60, 20), c(70, 30), c(80, 25)], deletes: &[] },
    Step { text: "put 35: p0 overflows, 2 siblings in, 3 out (split)", puts: &[c(35, 20)], deletes: &[] },
    Step { text: "put 15: p0 overflows again, 3 in, 3 out (redistribution)", puts: &[c(15, 20)], deletes: &[] },
    Step { text: "delete 70: p2 is more than 2/3 free, 3 in, 3 out (redistribution)", puts: &[], deletes: &[70] },
    Step { text: "delete 80: 3 in, 2 out (merge), p2 goes to the free list", puts: &[], deletes: &[80] },
];

fn fixed_scenario(w: &mut String) {
    w.push_str("\n== 2. Fixed scenario (capacity 100, 3 siblings, quick append, merge below 1/3) ==\n");
    let mut tree = Tree::new(Config { capacity: 100, ..Config::default() });
    for step in &SCENARIO {
        for cell in step.puts {
            tree.put(cell.key, cell.size).expect("scenario cells fit");
        }
        for &key in step.deletes {
            tree.delete(key);
        }
        tree.validate().expect("valid tree");
        writeln!(w, "{}", step.text).unwrap();
        tree.dump(w);
    }
    // Reads do not care how the cells are spread over the pages.
    let show = |size: Option<u32>| size.map_or("null".to_string(), |s| s.to_string());
    write!(w, "get 35 -> {}, get 70 -> {}, range [20, 50) ->", show(tree.get(35)), show(tree.get(70))).unwrap();
    let mut found = Vec::new();
    tree.range(20, 50, &mut found);
    for cell in &found {
        write!(w, " {}", cell.key).unwrap();
    }
    w.push('\n');
    let s = tree.stats;
    writeln!(
        w,
        "stats: balances={} quick_appends={} allocated={} freed={} leaf_writes={} parent_writes={} moved={} moved_to_old={}",
        s.balances, s.quick_appends, s.pages_allocated, s.pages_freed, s.leaf_writes, s.parent_writes, s.cells_moved, s.cells_moved_to_old
    )
    .unwrap();
}

pub const KEY_COUNT: u64 = 20_000;

/// Cell size for a key: 40..200 bytes, fixed per key so that every policy
/// sees the same cells whatever the insertion order.
pub fn size_of(key: u64) -> u32 {
    40 + SplitMix64::new(key).below(161) as u32
}

/// Keys 1..=KEY_COUNT, shuffled when `seed` is given.
fn make_keys(seed: Option<u64>) -> Vec<u64> {
    let mut keys: Vec<u64> = (1..=KEY_COUNT).collect();
    if let Some(seed) = seed {
        SplitMix64::new(seed).shuffle(&mut keys);
    }
    keys
}

fn print_row(w: &mut String, label: &str, tree: &Tree, since: Stats) {
    let s = tree.stats;
    let fill = tree.fill_permille();
    writeln!(
        w,
        "{label:<22}{:>6}{:>5}.{}%{:>9}{:>8}{:>8}{:>9}{:>9}",
        tree.child_count(),
        fill / 10,
        fill % 10,
        s.balances - since.balances,
        s.leaf_writes - since.leaf_writes,
        s.pages_freed - since.pages_freed,
        s.cells_moved - since.cells_moved,
        s.cells_moved_to_old - since.cells_moved_to_old
    )
    .unwrap();
}

const TABLE_HEADER: &str = "policy                 pages   fill balances  writes   freed    moved   to old\n";

/// (label, siblings, quick append)
const INSERT_POLICIES: [(&str, u8, bool); 5] = [
    ("split alone", 1, false),
    ("split alone + quick", 1, true),
    ("balance 2", 2, false),
    ("balance 3", 3, false),
    ("balance 3 + quick", 3, true),
];

fn insert_policies(w: &mut String) {
    writeln!(w, "\n== 3. Overflow policies: {KEY_COUNT} inserts, cells of 40..200 bytes, capacity 4096 ==").unwrap();
    for (name, seed) in [("ascending keys", None), ("random order", Some(15))] {
        let keys = make_keys(seed);
        write!(w, "-- {name} --\n{TABLE_HEADER}").unwrap();
        for (label, insert_siblings, quick_append) in INSERT_POLICIES {
            let mut tree =
                Tree::new(Config { insert_siblings, quick_append, merge: MergePolicy::Never, ..Config::default() });
            for &key in &keys {
                tree.put(key, size_of(key)).expect("cells fit");
            }
            tree.validate().expect("valid tree");
            print_row(w, label, &tree, Stats::default());
        }
    }
}

const MERGE_POLICIES: [(&str, MergePolicy); 4] = [
    ("never", MergePolicy::Never),
    ("at empty", MergePolicy::AtEmpty),
    ("below 1/3 (balance 3)", MergePolicy::BelowThird),
    ("below 1/2 (balance 3)", MergePolicy::BelowHalf),
];

fn build_random(merge: MergePolicy) -> Tree {
    let mut tree = Tree::new(Config { merge, ..Config::default() });
    for key in make_keys(Some(15)) {
        tree.put(key, size_of(key)).expect("cells fit");
    }
    tree
}

fn merge_policies(w: &mut String) {
    writeln!(w, "\n== 4. Underflow policies (tree built by {KEY_COUNT} random inserts, balance 3 + quick) ==").unwrap();
    write!(w, "-- delete 90% of the keys in random order (counters: the deletes only) --\n{TABLE_HEADER}").unwrap();
    let doomed = (KEY_COUNT / 10 * 9) as usize;
    for (label, merge) in MERGE_POLICIES {
        let mut tree = build_random(merge);
        let since = tree.stats;
        for &key in &make_keys(Some(16))[..doomed] {
            tree.delete(key);
        }
        tree.validate().expect("valid tree");
        print_row(w, label, &tree, since);
    }
    write!(w, "-- delete the 90% smallest keys, a queue being drained --\n{TABLE_HEADER}").unwrap();
    for (label, merge) in MERGE_POLICIES {
        let mut tree = build_random(merge);
        let since = tree.stats;
        for key in 1..=doomed as u64 {
            tree.delete(key);
        }
        tree.validate().expect("valid tree");
        print_row(w, label, &tree, since);
    }
    write!(
        w,
        "-- steady churn: {} times, toggle a random key (delete it if present, else insert it) --\n{TABLE_HEADER}",
        2 * KEY_COUNT
    )
    .unwrap();
    for (label, merge) in MERGE_POLICIES {
        let mut tree = build_random(merge);
        let since = tree.stats;
        let mut rng = SplitMix64::new(17);
        for _ in 0..2 * KEY_COUNT {
            let key = rng.range(1, KEY_COUNT + 1);
            if !tree.delete(key) {
                tree.put(key, size_of(key)).expect("cells fit");
            }
        }
        tree.validate().expect("valid tree");
        print_row(w, label, &tree, since);
    }
}

/// Everything `cargo run` prints.
pub fn write_report(w: &mut String) {
    redistribution_by_hand(w);
    fixed_scenario(w);
    insert_policies(w);
    merge_policies(w);
}
