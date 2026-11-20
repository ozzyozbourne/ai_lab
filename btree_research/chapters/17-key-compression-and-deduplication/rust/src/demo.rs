//! The chapter's deterministic program output: separators by hand, a small
//! fixed scenario (also embedded in the visualization), and fanout / space
//! measurements for the four combinations of truncation and deduplication.
use crate::prng::SplitMix64;
use crate::tree::{Config, LeafCell, PageId, Tid, Tree, separator};
use std::fmt::Write;

/// The fixed scenario: an index on a "fruit" column of a small table.
/// TIDs are row numbers; most rows arrive in order, the last few do not
/// (think of updates that reuse old row slots).
pub const SCENARIO: [(&str, Tid); 39] = [
    ("cherry", 1),
    ("apple", 2),
    ("blackberry", 3),
    ("apple", 4),
    ("fig", 5),
    ("blueberry", 6),
    ("apple", 7),
    ("cherry", 8),
    ("grape", 9),
    ("apple", 10),
    ("banana", 11),
    ("cherry", 12),
    ("apple", 13),
    ("elderberry", 14),
    ("apple", 16),
    ("cherry", 17),
    ("apricot", 18),
    ("apple", 19),
    ("cranberry", 20),
    ("cherry", 21),
    ("apple", 22),
    ("date", 23),
    ("cherry", 24),
    ("apple", 25),
    ("grapefruit", 26),
    ("cherry", 27),
    ("apple", 28),
    ("blackcurrant", 29),
    ("cherry", 30),
    ("apple", 31),
    ("avocado", 32),
    ("cherry", 33),
    ("guava", 34),
    ("apple", 35),
    ("cherry", 36),
    ("coconut", 37),
    ("apple", 15),
    ("cherry", 9),
    ("apple", 1),
];
pub const SCENARIO_PAGE_SIZE: usize = 256;

fn sep_text(key: &[u8], tid: Option<Tid>) -> String {
    let mut s = format!("\"{}\"", String::from_utf8_lossy(key));
    if let Some(tid) = tid {
        write!(s, "@{tid}").unwrap();
    }
    s
}

/// Depth-first dump. The visualization's JavaScript model prints the same
/// text for the same scenario; its self-test compares the two.
pub fn dump(out: &mut String, tree: &Tree, id: PageId, depth: usize) {
    let p = &tree.pages[id as usize];
    let fence = |sep: &Option<crate::tree::Sep>, infinity: &str| match sep {
        Some(s) => sep_text(&s.key, s.tid),
        None => infinity.to_string(),
    };
    writeln!(
        out,
        "{:indent$}page {id} {} low={} high={} used={}/{}",
        "",
        if p.is_leaf { "leaf" } else { "internal" },
        fence(&p.low, "-inf"),
        fence(&p.high, "+inf"),
        p.used_bytes(),
        tree.cfg.page_size,
        indent = depth * 2
    )
    .unwrap();
    write!(out, "{:indent$}", "", indent = depth * 2 + 2).unwrap();
    if p.is_leaf {
        let cells: Vec<String> = p
            .cells
            .iter()
            .map(|c| {
                let key = String::from_utf8_lossy(&c.key);
                if c.tids.len() == 1 {
                    format!("{key}@{}", c.tids[0])
                } else {
                    let tids: Vec<String> = c.tids.iter().map(Tid::to_string).collect();
                    format!("{key}@[{}]", tids.join(","))
                }
            })
            .collect();
        writeln!(out, "{}", cells.join(" ")).unwrap();
        return;
    }
    out.push_str("separators:");
    for s in &p.seps {
        write!(out, " {}", sep_text(&s.key, s.tid)).unwrap();
    }
    out.push('\n');
    for &child in &p.children {
        dump(out, tree, child, depth + 1);
    }
}

/// num / den with one decimal, computed in integers so that Zig and Rust
/// print the same digits.
fn tenths(num: usize, den: usize) -> String {
    if den == 0 {
        return "-".to_string();
    }
    let x = (num * 10 + den / 2) / den;
    format!("{}.{}", x / 10, x % 10)
}

fn config_name(cfg: &Config) -> &'static str {
    match (cfg.truncate, cfg.dedup) {
        (true, true) => "truncate + dedup",
        (true, false) => "truncate",
        (false, true) => "dedup",
        (false, false) => "neither",
    }
}

const TABLE_HEADER: &str =
    "  config            height  leaves  internal  fanout  sep bytes  bytes/entry  leaf splits  dedup passes\n";

fn stats_row(out: &mut String, tree: &Tree) {
    let s = tree.stats();
    writeln!(
        out,
        "  {:<16}  {:>6}  {:>6}  {:>8}  {:>6}  {:>9}  {:>11}  {:>11}  {:>12}",
        config_name(&tree.cfg),
        s.height,
        s.leaf_pages,
        s.internal_pages,
        tenths(s.children, s.internal_pages),
        tenths(s.sep_bytes, s.seps),
        tenths(s.used_bytes, s.entries),
        tree.counters.leaf_splits,
        tree.counters.dedup_passes
    )
    .unwrap();
}

#[derive(Clone, Copy)]
enum Workload {
    Hashes,
    Categories,
    Paths,
}

fn workload_key(rng: &mut SplitMix64, workload: Workload) -> String {
    match workload {
        // 32 hex digits, like a content hash: neighbours differ early.
        Workload::Hashes => {
            let a = rng.next_u64();
            let b = rng.next_u64();
            format!("{a:016x}{b:016x}")
        }
        // 50 distinct values, 400 rows each on average.
        Workload::Categories => format!("category-{:02}", rng.below(50)),
        // Hierarchical keys: neighbours share a long prefix and differ late.
        Workload::Paths => {
            let user = rng.below(2000);
            let order = rng.below(10000);
            format!("user/{user:06}/order/{order:06}")
        }
    }
}

/// The four combinations, in the order the tables print them.
fn configs(page_size: usize) -> [Config; 4] {
    [(false, false), (true, false), (false, true), (true, true)].map(|(truncate, dedup)| Config {
        page_size,
        truncate,
        dedup,
    })
}

fn measure(out: &mut String, workload: Workload, n: u64) {
    out.push_str(TABLE_HEADER);
    for cfg in configs(4096) {
        let mut tree = Tree::new(cfg);
        let mut rng = SplitMix64::new(17); // same keys for every configuration
        for i in 0..n {
            tree.put(workload_key(&mut rng, workload).as_bytes(), i).unwrap();
        }
        tree.validate().unwrap();
        stats_row(out, &tree);
    }
}

pub fn run(out: &mut String) {
    out.push_str("== 1. Separators are not keys ==\n");
    out.push_str("  last on left       first on right     full separator     truncated separator\n");
    for ((lk, lt), (rk, rt)) in [
        (("banana", 11), ("blackberry", 3)),
        (("blackberry", 3), ("blueberry", 6)),
        (("grape", 9), ("grapefruit", 26)),
        (("date", 23), ("dates", 40)),
        (("cherry", 12), ("cherry", 17)),
    ] {
        let l = LeafCell { key: lk.as_bytes().to_vec(), tids: vec![lt] };
        let r = LeafCell { key: rk.as_bytes().to_vec(), tids: vec![rt] };
        let (full_key, full_tid) = separator(false, &l, &r);
        let (short_key, short_tid) = separator(true, &l, &r);
        writeln!(
            out,
            "  {:<17}  {:<17}  {:<17}  {}",
            sep_text(&l.key, Some(lt)),
            sep_text(&r.key, Some(rt)),
            sep_text(full_key, full_tid),
            sep_text(short_key, short_tid)
        )
        .unwrap();
    }

    writeln!(out, "\n== 2. Fixed scenario: {} puts, page_size = {SCENARIO_PAGE_SIZE} ==", SCENARIO.len()).unwrap();
    let mut tree = Tree::new(Config { page_size: SCENARIO_PAGE_SIZE, ..Config::default() });
    for (key, tid) in SCENARIO {
        tree.put(key.as_bytes(), tid).unwrap();
    }
    tree.validate().unwrap();
    dump(out, &tree, tree.root, 0);
    writeln!(out, "  posting list splits (a TID landed inside a posting list): {}", tree.counters.posting_swaps)
        .unwrap();
    out.push_str("\n  The same puts under each configuration:\n");
    out.push_str(TABLE_HEADER);
    for cfg in configs(SCENARIO_PAGE_SIZE) {
        let mut other = Tree::new(cfg);
        for (key, tid) in SCENARIO {
            other.put(key.as_bytes(), tid).unwrap();
        }
        other.validate().unwrap();
        stats_row(out, &other);
    }

    out.push_str("\n== 3. Searching through truncated separators ==\n");
    for key in ["apple", "blueberry", "cherry", "c", "coconut", "kiwi"] {
        write!(out, "  get(\"{key}\"): page {}", tree.root).unwrap();
        let mut id = tree.root;
        while !tree.pages[id as usize].is_leaf {
            let page = &tree.pages[id as usize];
            let i = Tree::child_index(page, key.as_bytes(), 0);
            id = page.children[i];
            write!(out, " -> child {i} = page {id}").unwrap();
        }
        let tids: Vec<String> = tree.get(key.as_bytes()).iter().map(Tid::to_string).collect();
        writeln!(out, " -> [{}]", tids.join(",")).unwrap();
    }

    out.push_str("\n== 4. Measurements, page_size = 4096 ==\n");
    out.push_str("A. 20000 unique 32-byte keys (hex hashes), random order\n");
    measure(out, Workload::Hashes, 20000);
    out.push_str("B. 20000 rows over 50 distinct keys (\"category-NN\")\n");
    measure(out, Workload::Categories, 20000);
    out.push_str("C. 20000 hierarchical keys (\"user/NNNNNN/order/NNNNNN\"), random order\n");
    measure(out, Workload::Paths, 20000);
    out.push_str(
        "\nfanout      = average number of children per internal page\n\
         sep bytes   = average separator payload in internal pages (key bytes, plus 6 when a TID is kept)\n\
         bytes/entry = bytes in use on all pages / number of (key, TID) entries\n",
    );
}
