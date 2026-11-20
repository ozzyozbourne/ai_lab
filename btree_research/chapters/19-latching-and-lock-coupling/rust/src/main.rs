//! Demo program of chapter 19. Its stdout is exactly ../expected_output.txt
//! (checked by the test at the bottom) and is identical to the Zig program's.
//!
//! Sections 3, 4, 6 and 7 start threads, and still print the same text on
//! every run: sections 3, 4 and 7 because the other threads only run while
//! the first is frozen by the test hook, section 6 because it prints only
//! facts that do not depend on the interleaving.

use std::io::{self, Write};
use std::sync::atomic::Ordering;
use std::thread;

use ch19_latching_and_lock_coupling::dump::{dump, dump_to_string};
use ch19_latching_and_lock_coupling::ops::{Config, Op, OpStream, Oracle, Weights};
use ch19_latching_and_lock_coupling::probe::{self, Actor, OpSpec, Outcome, Pause, value_of};
use ch19_latching_and_lock_coupling::{
    CANONICAL, PROTOCOLS, Point, Protocol, Tree, protocol_name, stress,
};

fn main() -> io::Result<()> {
    let stdout = io::stdout();
    let mut w = io::BufWriter::new(stdout.lock());
    run(&mut w)?;
    w.flush()
}

fn run(w: &mut dyn Write) -> io::Result<()> {
    build_demo(w)?;
    model_run(w)?;
    probe_demo(w)?;
    root_demo(w)?;
    out_of_nodes_demo(w)?;
    stress_demo(w)?;
    convoy_demo(w)
}

fn canonical_tree(protocol: Protocol) -> Tree {
    let tree = Tree::new(4, protocol, 64);
    for key in CANONICAL {
        tree.put(key, value_of(key)).expect("64 nodes are enough");
    }
    tree
}

fn build_demo(w: &mut dyn Write) -> io::Result<()> {
    writeln!(
        w,
        "== 1. One tree, three protocols: canonical keys, order M = 4 =="
    )?;
    let mut reference: Option<String> = None;
    for protocol in PROTOCOLS {
        let tree = canonical_tree(protocol);
        tree.validate().expect("valid");
        let text = dump_to_string(&tree);
        match &reference {
            Some(r) => writeln!(
                w,
                "{}: same tree: {}",
                protocol_name(protocol),
                if *r == text { "yes" } else { "NO" }
            )?,
            None => {
                write!(w, "{}:\n  {}", protocol_name(protocol), text)?;
                reference = Some(text);
            }
        }
    }
    Ok(())
}

/// A seeded single-threaded workload against the reference oracle.
fn model_run(w: &mut dyn Write) -> io::Result<()> {
    writeln!(
        w,
        "\n== 2. Model run: 20000 single-threaded operations (put, get) against the oracle =="
    )?;
    for protocol in PROTOCOLS {
        let tree = Tree::new(4, protocol, 2048);
        let mut oracle = Oracle::new();
        let stream = OpStream::new(Config {
            seed: 19,
            count: 20_000,
            key_space: 500,
            weights: Weights {
                put: 1,
                delete: 0,
                get: 1,
                range: 0,
            },
        });
        let mut mismatches = 0usize;
        for op in stream {
            match op {
                Op::Put { key, value } => {
                    let got = tree.put(key, value).expect("2048 nodes are enough");
                    if got != oracle.put(key, value) {
                        mismatches += 1;
                    }
                }
                Op::Get { key } => {
                    if tree.get(key) != oracle.get(key) {
                        mismatches += 1;
                    }
                }
                Op::Delete { .. } | Op::Range { .. } => unreachable!("weight 0"),
            }
        }
        tree.validate().expect("valid");
        writeln!(
            w,
            "{:<14} keys={} height={} nodes={} leaf splits={} internal splits={} mismatches={}",
            protocol_name(protocol),
            tree.len(),
            tree.height(),
            tree.table.count(),
            tree.stats.leaf_splits.load(Ordering::Relaxed),
            tree.stats.internal_splits.load(Ordering::Relaxed),
            mismatches
        )?;
    }
    Ok(())
}

struct Scenario {
    /// Extra keys put before the experiment.
    setup: &'static [u64],
    title: &'static str,
    frozen: OpSpec,
    others: &'static [(OpSpec, &'static str)],
}

const SCENARIOS: [Scenario; 4] = [
    Scenario {
        setup: &[],
        title: "A = get 12 (latch coupling holds: #1 shared)",
        frozen: OpSpec::Get(12),
        others: &[
            (OpSpec::Get(25), "other leaf"),
            (OpSpec::Get(10), "same leaf"),
            (OpSpec::Put(16), "other leaf"),
            (OpSpec::Put(11), "same leaf"),
        ],
    },
    Scenario {
        setup: &[],
        title: "A = put 11 (latch coupling holds: #1 exclusive; leaf #1 has room)",
        frozen: OpSpec::Put(11),
        others: &[
            (OpSpec::Get(25), "other leaf"),
            (OpSpec::Get(12), "same leaf"),
            (OpSpec::Put(16), "other leaf"),
        ],
    },
    Scenario {
        setup: &[],
        title: "A = put 26 (latch coupling holds: #6, #3 exclusive; leaf #3 is full, its parent #6 has room)",
        frozen: OpSpec::Put(26),
        others: &[
            (OpSpec::Get(12), "under #2"),
            (OpSpec::Put(11), "under #2"),
            (OpSpec::Get(17), "under #6"),
        ],
    },
    Scenario {
        setup: &[8, 9],
        title: "after put 8, put 9: A = put 2 (latch coupling holds: #7, #2, #0 exclusive; leaf #0 and its parent #2 are full)",
        frozen: OpSpec::Put(2),
        others: &[(OpSpec::Get(25), "under #6")],
    },
];

fn probe_demo(w: &mut dyn Write) -> io::Result<()> {
    writeln!(
        w,
        "\n== 3. A is frozen at the end of its descent, holding its locks. Does B finish? (canonical tree) =="
    )?;
    for s in &SCENARIOS {
        writeln!(w, "{}", s.title)?;
        writeln!(
            w,
            "  {:<22} global mutex    global rwlock   latch coupling",
            "B"
        )?;
        for &(op, note) in s.others {
            let label = format!("{} {} ({})", op.name(), op.key(), note);
            write!(w, "  {label:<22}")?;
            for protocol in PROTOCOLS {
                let tree = canonical_tree(protocol);
                for &key in s.setup {
                    tree.put(key, value_of(key)).expect("64 nodes are enough");
                }
                let outcome = probe::probe(&tree, s.frozen, Pause::at(Point::AtLeaf), op)
                    .map_err(|e| io::Error::other(format!("{e:?}")))?;
                tree.validate().expect("valid");
                let cell = match outcome {
                    Outcome::Completed => "finishes".to_string(),
                    Outcome::Blocked(node) if node.is_nil() => "waits".to_string(),
                    Outcome::Blocked(node) => format!("waits at #{}", node.index()),
                };
                // The last column is not padded: no trailing spaces.
                if protocol == Protocol::LatchCoupling {
                    write!(w, " {cell}")?;
                } else {
                    write!(w, " {cell:<15}")?;
                }
            }
            writeln!(w)?;
        }
    }
    Ok(())
}

/// The root is replaced between "read the root id" and "latch that node".
fn root_demo(w: &mut dyn Write) -> io::Result<()> {
    writeln!(
        w,
        "\n== 4. Latch coupling: the root is replaced under a reader =="
    )?;
    let tree = Tree::new(4, Protocol::LatchCoupling, 16);
    for key in [10, 20, 5] {
        tree.put(key, value_of(key)).expect("16 nodes are enough");
    }
    write!(w, "before: ")?;
    dump(&tree, w)?;

    let reader = Actor::new(&tree, OpSpec::Get(20), Some(Pause::at(Point::RootLoaded)));
    let result = thread::scope(|scope| -> io::Result<Option<u64>> {
        let handle = scope.spawn(|| reader.run());
        reader.wait_settled();
        // Whatever happens below, release the reader before leaving the scope.
        let middle = (|| -> io::Result<()> {
            writeln!(
                w,
                "reader of 20 has read root = #0 and holds no latch yet; now put 6 splits the root"
            )?;
            tree.put(6, value_of(6)).map_err(io::Error::other)?;
            write!(w, "after:  ")?;
            dump(&tree, w)
        })();
        reader.release();
        let result = handle.join().expect("reader panicked");
        middle?;
        result.map_err(io::Error::other)
    })?;
    writeln!(
        w,
        "reader latched #0, saw root = #{}, restarted {} time(s): get 20 = {}",
        tree.root().index(),
        tree.stats.root_restarts.load(Ordering::Relaxed),
        result.map_or("null".to_string(), |v| v.to_string())
    )
}

fn out_of_nodes_demo(w: &mut dyn Write) -> io::Result<()> {
    writeln!(
        w,
        "\n== 5. A node table of 7: put 15 needs 3 new nodes (leaf, internal, root) =="
    )?;
    for protocol in PROTOCOLS {
        let tree = Tree::new(4, protocol, 7);
        for key in CANONICAL {
            let before = dump_to_string(&tree);
            let used = tree.table.count();
            if tree.put(key, value_of(key)).is_err() {
                tree.validate().expect("valid");
                writeln!(
                    w,
                    "{:<14} put {}: OutOfNodes; nodes used {} -> {} of 7; tree unchanged: {}; locks still held: {}",
                    protocol_name(protocol),
                    key,
                    used,
                    tree.table.count(),
                    if before == dump_to_string(&tree) {
                        "yes"
                    } else {
                        "NO"
                    },
                    if tree.nothing_locked() {
                        "none"
                    } else {
                        "SOME"
                    }
                )?;
                break;
            }
        }
    }
    Ok(())
}

fn stress_demo(w: &mut dyn Write) -> io::Result<()> {
    writeln!(
        w,
        "\n== 6. Stress: 4 threads x 5000 operations, then validate and compare with the oracle =="
    )?;
    for overlapping in [false, true] {
        for protocol in PROTOCOLS {
            let config = stress::Config {
                threads: 4,
                ops_per_thread: 5000,
                seed: if overlapping { 1902 } else { 1901 },
                key_space: if overlapping { 3000 } else { 750 },
                overlapping,
            };
            let tree = Tree::new(4, protocol, config.node_capacity());
            let r = stress::run(&tree, config);
            writeln!(
                w,
                "{} {:<14} keys={} expected={} first-time puts={} lost={} failed={} mismatches={} valid={}",
                if overlapping {
                    "overlapping keys"
                } else {
                    "disjoint keys   "
                },
                protocol_name(protocol),
                r.keys,
                r.expected_keys,
                r.fresh,
                r.lost,
                r.failed,
                r.mismatches,
                if r.valid { "yes" } else { "NO" }
            )?;
        }
    }
    Ok(())
}

/// Four threads. A waiting thread keeps the latches it already has, so a
/// thread can be stopped by one that is itself only waiting.
fn convoy_demo(w: &mut dyn Write) -> io::Result<()> {
    writeln!(
        w,
        "\n== 7. Latch coupling, four threads: A = put 26 is frozen as in section 3; then B, C, D start, one after the other =="
    )?;
    let tree = canonical_tree(Protocol::LatchCoupling);
    let others = [
        (OpSpec::Get(17), "under #6"),
        (OpSpec::Get(12), "under #2"),
        (OpSpec::Put(11), "under #2"),
    ];
    let ops = others.map(|(op, _)| op);
    let outcomes = probe::convoy(&tree, OpSpec::Put(26), Pause::at(Point::AtLeaf), &ops)
        .map_err(|e| io::Error::other(format!("{e:?}")))?;
    for (((op, note), outcome), name) in others.into_iter().zip(outcomes).zip("BCD".chars()) {
        let label = format!("{} {} ({})", op.name(), op.key(), note);
        match outcome {
            Outcome::Completed => writeln!(w, "  {name} = {label:<18} finishes")?,
            Outcome::Blocked(node) => {
                writeln!(w, "  {name} = {label:<18} waits at #{}", node.index())?;
            }
        }
    }
    writeln!(
        w,
        "D needs nothing that A holds. It waits for the shared latch B keeps on the root #7 while B itself waits at #6."
    )?;
    tree.validate().expect("valid");
    let show = |v: Option<u64>| v.map_or("null".to_string(), |v| v.to_string());
    writeln!(
        w,
        "after A is released: get 26 = {}, get 11 = {}, valid=yes, latches still held: {}",
        show(tree.get(26)),
        show(tree.get(11)),
        if tree.nothing_locked() {
            "none"
        } else {
            "SOME"
        }
    )
}

#[cfg(test)]
mod tests {
    #[test]
    fn run_prints_exactly_expected_output_txt() {
        let mut out = Vec::new();
        super::run(&mut out).unwrap();
        assert_eq!(
            String::from_utf8(out).unwrap(),
            include_str!("../../expected_output.txt")
        );
    }
}
