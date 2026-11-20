//! Demo program of chapter 20. Its stdout is exactly ../expected_output.txt
//! (checked by the test at the bottom) and is identical to the Zig program's.

use std::io::{self, Write};

use ch20_blink_trees::ops::{Config, Op, OpStream, Oracle, Weights};
use ch20_blink_trees::prng::SplitMix64;
use ch20_blink_trees::{BLinkTree, Descent, Mode, Step, dump, stress};

/// Canonical hand example of chapters 03 to 08.
const CANONICAL: [u64; 12] = [10, 20, 5, 6, 12, 30, 7, 17, 3, 25, 1, 15];

/// The node tables of this program are large enough for what it inserts.
const ROOM: &str = "node table large enough";

fn main() -> io::Result<()> {
    let mut out = io::BufWriter::new(io::stdout().lock());
    run(&mut out)?;
    out.flush()
}

/// Zig prints an optional integer with `{?d}`: the number, or `null`.
fn optional(value: Option<u64>) -> String {
    value.map_or_else(|| "null".to_string(), |v| v.to_string())
}

fn run(w: &mut dyn Write) -> io::Result<()> {
    let tree = BLinkTree::new(4, 64);

    writeln!(
        w,
        "== 1. Build: canonical keys, order M = 4; every node has a high key and a right link =="
    )?;
    for key in CANONICAL {
        tree.put(key, key * 100).expect(ROOM);
    }
    tree.validate().expect("valid tree");
    dump::dump(&tree, w)?;
    writeln!(
        w,
        "legend: #n node, [..] separators, (..) leaf keys, <k high key (keys in the node are below k), -> right link"
    )?;

    writeln!(w, "\n== 2. Step 1 of a split, and nothing else ==")?;
    writeln!(
        w,
        "put 26 into the full leaf #3(20 25 30); the writer stops between the two steps"
    )?;
    tree.set_abandon_splits(true);
    tree.put(26, 2600).expect(ROOM);
    tree.set_abandon_splits(false);
    tree.validate().expect("valid tree");
    dump::dump(&tree, w)?;
    writeln!(
        w,
        "incomplete splits: {}; validate: ok",
        tree.incomplete_splits()
    )?;

    writeln!(w, "\n== 3. Searching in that state ==")?;
    for key in [25, 26, 30] {
        let r = tree.lookup(key, Mode::FollowRightLinks);
        writeln!(
            w,
            "get {key} = {} (visited {} nodes, moved right {})",
            optional(r.value),
            r.visited,
            r.moves_right
        )?;
    }
    for key in [25, 26, 30] {
        let r = tree.lookup(key, Mode::IgnoreRightLinks);
        let note = if r.value.is_none() { "  <- MISSED" } else { "" };
        writeln!(
            w,
            "without right links: get {key} = {}{note}",
            optional(r.value)
        )?;
    }
    let mut keys = CANONICAL.to_vec();
    keys.push(26);
    print_found(w, &tree, &keys)?;

    writeln!(w, "\n== 4. The next writer finishes the split ==")?;
    writeln!(
        w,
        "put 27: lands on #3, sees the flag, inserts the downlink to #8 first, then does its own work"
    )?;
    let before = tree.stats();
    tree.put(27, 2700).expect(ROOM);
    let after = tree.stats();
    tree.validate().expect("valid tree");
    dump::dump(&tree, w)?;
    writeln!(
        w,
        "splits finished by a later writer: {}; incomplete splits: {}",
        after.finished_later - before.finished_later,
        tree.incomplete_splits()
    )?;
    keys.push(27);
    print_found(w, &tree, &keys)?;

    writeln!(
        w,
        "\n== 5. A reader overtaken by a complete split (stale downlink) =="
    )?;
    for mode in [Mode::FollowRightLinks, Mode::IgnoreRightLinks] {
        // Each pass splits one leaf: #8 in the first pass, #9 in the second.
        let (split_key, probe, title) = if mode == Mode::FollowRightLinks {
            (28, 30, "with right links")
        } else {
            (31, 32, "without right links")
        };
        tree.put(probe, probe * 100).expect(ROOM);
        writeln!(w, "{title}: get {probe}")?;
        let mut reader = Descent::begin(&tree, probe, mode);
        // Two visits: the root, then the level-1 node. The reader now holds
        // the handle of a leaf and no latch.
        for _ in 0..2 {
            let step = reader.step(&tree);
            print_step(w, &tree, probe, step)?;
        }
        let halves = tree.stats().half_splits;
        tree.put(split_key, split_key * 100).expect(ROOM);
        writeln!(
            w,
            "  writer: put {split_key} splits that leaf, both steps (half splits +{}, incomplete {})",
            tree.stats().half_splits - halves,
            tree.incomplete_splits()
        )?;
        loop {
            let step = reader.step(&tree);
            print_step(w, &tree, probe, step)?;
            if matches!(step, Step::Done { .. }) {
                break;
            }
        }
    }
    tree.validate().expect("valid tree");
    dump::dump(&tree, w)?;

    root_split_demo(w)?;
    model_run(w)?;
    stress_run(w)
}

fn print_found(w: &mut dyn Write, tree: &BLinkTree, keys: &[u64]) -> io::Result<()> {
    let found = |mode| {
        keys.iter()
            .filter(|&&key| tree.lookup(key, mode).value.is_some())
            .count()
    };
    writeln!(
        w,
        "keys found: {} of {} with right links, {} of {} without",
        found(Mode::FollowRightLinks),
        keys.len(),
        found(Mode::IgnoreRightLinks),
        keys.len()
    )
}

fn print_step(w: &mut dyn Write, tree: &BLinkTree, key: u64, step: Step) -> io::Result<()> {
    write!(w, "  reader: visits ")?;
    match step {
        Step::Descended { from, to } => {
            dump::print_node(tree, from, w)?;
            writeln!(w, ", follows the downlink to #{}", to.index())
        }
        Step::MovedRight { from, to, high_key } => {
            dump::print_node(tree, from, w)?;
            writeln!(
                w,
                ", {key} >= high key {high_key}, follows the right link to #{}",
                to.index()
            )
        }
        Step::Done { leaf, value } => {
            dump::print_node(tree, leaf, w)?;
            match value {
                Some(v) => writeln!(w, ", finds {key} = {v}"),
                None => writeln!(w, ", does not find {key}  <- MISSED"),
            }
        }
    }
}

/// The root is not special: its split is the same two steps, and step 2 is
/// "build a new root".
fn root_split_demo(w: &mut dyn Write) -> io::Result<()> {
    writeln!(w, "\n== 6. A root split is the same two steps ==")?;
    let tree = BLinkTree::new(4, 8);
    for key in [1, 2, 3] {
        tree.put(key, key * 100).expect(ROOM);
    }
    tree.set_abandon_splits(true);
    tree.put(4, 400).expect(ROOM);
    tree.set_abandon_splits(false);
    writeln!(
        w,
        "put 4, stopped after step 1: the root has a right sibling and there is no new root yet"
    )?;
    tree.validate().expect("valid tree");
    dump::dump(&tree, w)?;
    let r = tree.lookup(4, Mode::FollowRightLinks);
    writeln!(
        w,
        "get 4 = {} (moved right {})",
        optional(r.value),
        r.moves_right
    )?;
    tree.put(5, 500).expect(ROOM);
    writeln!(
        w,
        "put 5 finishes it: step 2 of a root split builds the new root"
    )?;
    tree.validate().expect("valid tree");
    dump::dump(&tree, w)
}

/// A seeded single-threaded workload against the reference oracle. A seeded
/// coin decides before every put whether splits are abandoned after step 1,
/// so the tree is full of half-finished splits most of the time.
fn model_run(w: &mut dyn Write) -> io::Result<()> {
    writeln!(
        w,
        "\n== 7. Model run: 20000 puts and gets, a seeded coin abandons splits after step 1 =="
    )?;
    for order in [3, 4, 16] {
        let tree = BLinkTree::new(order, 4096);
        let mut oracle = Oracle::new();
        let stream = OpStream::new(Config {
            seed: 20,
            count: 20_000,
            key_space: 2000,
            weights: Weights {
                put: 4,
                delete: 0,
                get: 3,
                range: 0,
            },
        });
        let mut coin = SplitMix64::new(99);
        let mut mismatches = 0;
        let mut missed_without = 0;
        for op in stream {
            match op {
                Op::Put { key, value } => {
                    tree.set_abandon_splits(coin.chance(1, 4));
                    if tree.put(key, value).expect(ROOM) != oracle.put(key, value) {
                        mismatches += 1;
                    }
                }
                Op::Get { key } => {
                    let expected = oracle.get(key);
                    if tree.get(key) != expected {
                        mismatches += 1;
                    }
                    if tree.lookup(key, Mode::IgnoreRightLinks).value != expected {
                        missed_without += 1;
                    }
                }
                Op::Delete { .. } | Op::Range { .. } => unreachable!("weight 0"),
            }
        }
        tree.validate().expect("valid tree");
        let s = tree.stats();
        writeln!(
            w,
            "M={order:<2} keys={} height={} nodes={} | half splits={} completed={} (by a later writer={}) still incomplete={} | gets wrong={mismatches}, wrong without right links={missed_without}",
            tree.len(),
            tree.height(),
            tree.node_count(),
            s.half_splits,
            s.completed_splits,
            s.finished_later,
            tree.incomplete_splits(),
        )?;
    }
    Ok(())
}

fn stress_run(w: &mut dyn Write) -> io::Result<()> {
    writeln!(
        w,
        "\n== 8. Stress: 4 threads, 4000 seeded puts each, every put followed by 3 gets =="
    )?;
    for abandon in [false, true] {
        let r = stress::run(&stress::Config {
            order: 4,
            threads: stress::MAX_THREADS,
            puts_per_thread: 4000,
            key_space: 6000,
            preload: 500,
            seed: 2020,
            capacity: 8192,
            abandon_splits: abandon,
        });
        write!(
            w,
            "{}: keys={} expected={} lost reads={} failed puts={} mismatches={} validate={}",
            if abandon {
                "every split abandoned after step 1"
            } else {
                "normal splits"
            },
            r.keys,
            r.expected_keys,
            r.lost,
            r.failed_puts,
            r.mismatches,
            if r.valid { "ok" } else { "FAILED" },
        )?;
        // With the hook on, how many flags are left depends on the
        // interleaving, so it is not printed.
        if !abandon {
            write!(w, " incomplete splits={}", r.incomplete_splits)?;
        }
        writeln!(w)?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    #[test]
    fn run_prints_exactly_expected_output_txt() {
        let mut out = Vec::new();
        super::run(&mut out).expect("writing to a Vec cannot fail");
        assert_eq!(
            String::from_utf8(out).expect("utf-8"),
            include_str!("../../expected_output.txt")
        );
    }
}
