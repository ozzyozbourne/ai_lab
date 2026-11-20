//! The fixed scenario printed by `cargo run` (and by `zig build run`, byte
//! for byte). The chapter README quotes this output and the visualization
//! reproduces part 4 with a JavaScript port of the fuzzer.

use crate::base_btree::{BTree, Bug};
use crate::base_validate::ValidateError;
use crate::coverage::{Coverage, POINT_COUNT, Point};
use crate::fuzz::{self, Case, Checks, Kind, Subject, Totals};
use crate::minimize::minimize;
use std::error::Error;
use std::io::Write;

/// Node orders the sweep runs: the smallest legal one, the guide's default,
/// and one odd and one even order above it (odd and even split differently).
pub const ORDERS: [usize; 4] = [3, 4, 5, 6];
pub const SWEEP_SEEDS: u64 = 150;
pub const HUNT_SEEDS: u64 = 200;
pub const BUGS: [Bug; 3] = [
    Bug::SplitWrongValue,
    Bug::MergeLeaksNode,
    Bug::BorrowForgetsChild,
];

pub fn run(w: &mut dyn Write) -> Result<(), Box<dyn Error>> {
    writeln!(w, "== 1. One seed is one test case ==")?;
    for seed in [1, 2, 3] {
        let case = fuzz::swarm(seed);
        print_case(w, case)?;
        let steps = fuzz::generate(case);
        let mut totals = Totals::default();
        let failure = fuzz::replay(
            Subject::correct(4),
            &steps,
            Checks::default(),
            Some(&mut totals),
        );
        writeln!(
            w,
            "  M=4: {} steps replayed, {} allocation failures injected, max height {}, max keys {}: {}",
            totals.steps,
            totals.injected_faults,
            totals.max_height,
            totals.max_keys,
            if failure.is_none() { "ok" } else { "FAILED" }
        )?;
    }

    writeln!(
        w,
        "\n== 2. Swarm sweep of the correct tree: seeds 1..{SWEEP_SEEDS} at each order =="
    )?;
    let mut all = Coverage::default();
    for order in ORDERS {
        let mut totals = Totals::default();
        let found = fuzz::hunt(
            Subject::correct(order),
            1,
            SWEEP_SEEDS,
            Checks::default(),
            Some(&mut totals),
        );
        writeln!(
            w,
            "M={order}: {} cases, {} steps, {} injected allocation failures, max height {}, coverage {}/{POINT_COUNT}: {}",
            totals.cases,
            totals.steps,
            totals.injected_faults,
            totals.max_height,
            totals.coverage.reached(),
            if found.is_none() { "ok" } else { "FAILED" }
        )?;
        all.add(&totals.coverage);
    }
    writeln!(w, "hits per coverage point, all orders together:")?;
    for point in Point::ALL {
        writeln!(w, "  {:<22} {}", point.name(), all.count(point))?;
    }
    // Tiny nodes are a test parameter, not a detail: the same seeds with 31
    // keys per node never touch an interior node.
    let mut large = Totals::default();
    fuzz::hunt(
        Subject::correct(32),
        1,
        SWEEP_SEEDS,
        Checks::default(),
        Some(&mut large),
    );
    print_reach(w, "the same seeds at M=32", &large)?;

    writeln!(
        w,
        "\n== 3. A fixed mix against the swarm (M = 4, seeds 1..{SWEEP_SEEDS}) =="
    )?;
    let mut fixed = Totals::default();
    for seed in 1..=SWEEP_SEEDS {
        let steps = fuzz::generate(fuzz::fixed_mix(seed));
        fuzz::replay(
            Subject::correct(4),
            &steps,
            Checks::default(),
            Some(&mut fixed),
        );
    }
    let mut swarmed = Totals::default();
    fuzz::hunt(
        Subject::correct(4),
        1,
        SWEEP_SEEDS,
        Checks::default(),
        Some(&mut swarmed),
    );
    print_reach(w, "fixed mix", &fixed)?;
    print_reach(w, "swarm    ", &swarmed)?;

    writeln!(
        w,
        "\n== 4. Three broken trees (M = 4, swarm seeds 1..{HUNT_SEEDS}) =="
    )?;
    for bug in BUGS {
        hunt_and_minimize(Subject { order: 4, bug }, w)?;
    }

    writeln!(
        w,
        "\n== 5. Fault injection: fail every node allocation of every put once =="
    )?;
    let sweep = fault_sweep(4, 40);
    writeln!(
        w,
        "puts={} nodes created={} injected failures={} reserved nodes handed back={}",
        sweep.puts, sweep.nodes_created, sweep.injected, sweep.handed_back
    )?;
    writeln!(
        w,
        "tree unchanged after every failed put: {}; live allocations after deinit: {}",
        if sweep.unchanged { "yes" } else { "NO" },
        sweep.live_after_deinit
    )?;
    Ok(())
}

fn print_case(w: &mut dyn Write, case: Case) -> std::io::Result<()> {
    write!(
        w,
        "seed {}: {} ops on {} keys {}, put:delete:get:range = {}:{}:{}:{}, ",
        case.seed,
        case.count,
        case.key_space,
        case.key_layout.describe(),
        case.weights.put,
        case.weights.delete,
        case.weights.get,
        case.weights.range
    )?;
    if case.fault_one_in == 0 {
        write!(w, "no faults")?;
    } else {
        write!(w, "fault in 1 of {} puts", case.fault_one_in)?;
    }
    writeln!(w, ", drain {}", if case.drain { "yes" } else { "no" })
}

fn print_reach(w: &mut dyn Write, label: &str, totals: &Totals) -> std::io::Result<()> {
    write!(
        w,
        "{label}: {} steps, max height {}, coverage {}/{POINT_COUNT}",
        totals.steps,
        totals.max_height,
        totals.coverage.reached()
    )?;
    let mut first = true;
    for point in Point::ALL {
        if totals.coverage.count(point) != 0 {
            continue;
        }
        let lead = if first { ", never reached: " } else { ", " };
        write!(w, "{lead}{}", point.name())?;
        first = false;
    }
    writeln!(w)
}

/// Find the swarm seed that exposes the bug in the fewest steps, show which
/// family of checks is needed to see it, and print the minimised reproducer.
fn hunt_and_minimize(subject: Subject, w: &mut dyn Write) -> std::io::Result<()> {
    writeln!(w, "bug {}", subject.bug.name())?;
    let census = fuzz::hunt_shortest(subject, 1, HUNT_SEEDS, Checks::default());
    let Some(found) = census.shortest else {
        return writeln!(w, "  NOT CAUGHT");
    };
    let steps = fuzz::generate(found.case);
    writeln!(
        w,
        "  caught by {} of {HUNT_SEEDS} seeds; shortest failing run: seed {}, step {} of {}",
        census.failing_seeds,
        found.case.seed,
        found.failure.step + 1,
        steps.len()
    )?;
    writeln!(w, "  {}", found.failure)?;
    // Which half of the checks does the work? Replay the same steps with one
    // half switched off. (Only meaningful because of what these three bugs
    // do: see the README.)
    if let Kind::Invariant(error) = found.failure.kind {
        let without_validate = Checks {
            validate: false,
            ..Checks::default()
        };
        let silent = error == ValidateError::NodeCountMismatch
            && fuzz::replay(subject, &steps, without_validate, None).is_none();
        writeln!(
            w,
            "  with the oracle comparison alone: {}",
            if silent {
                "not caught"
            } else {
                "not tried (the tree is malformed)"
            }
        )?;
    } else {
        let without_model = Checks {
            model: false,
            ..Checks::default()
        };
        let silent = fuzz::replay(subject, &steps, without_model, None).is_none();
        writeln!(
            w,
            "  with validate alone: {}",
            if silent { "not caught" } else { "caught" }
        )?;
    }
    let small = minimize(subject, &steps, found.failure, Checks::default());
    writeln!(
        w,
        "  minimised to {} steps in {} replays:",
        small.steps.len(),
        small.replays
    )?;
    fuzz::write_steps(w, &small.steps, "    ")?;
    writeln!(w, "    -> {}", small.failure)
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct FaultSweep {
    pub puts: u64,
    pub nodes_created: u64,
    pub injected: u64,
    pub handed_back: u64,
    pub unchanged: bool,
    pub live_after_deinit: i64,
}

/// Insert the keys 1..=count. For each put, fail its first node allocation,
/// then (on a fresh attempt) its second, and so on until the put gets
/// through. After each failure the tree must be exactly as before.
///
/// `live_after_deinit` is measured by the counting global allocator: heap
/// allocations of this thread that outlive the tree (the Zig twin counts
/// with its allocator wrapper).
pub fn fault_sweep(order: usize, count: u64) -> FaultSweep {
    let live_before = crate::alloc_count::stats().live();
    let mut result = FaultSweep {
        puts: 0,
        nodes_created: 0,
        injected: 0,
        handed_back: 0,
        unchanged: true,
        live_after_deinit: 0,
    };
    let mut tree = BTree::new(order);
    for key in 1..=count {
        let mut n = 0;
        loop {
            let usage_before = tree.pool.usage;
            let slots_before = tree.pool.live_slots();
            tree.pool.fail_after = Some(n);
            let outcome = tree.put(key, key * 10);
            tree.pool.fail_after = None;
            if outcome.is_ok() {
                break;
            }
            result.injected += 1;
            result.handed_back += n; // n nodes were reserved before the failure
            let same = tree.len as u64 == key - 1
                && tree.get(key).is_none()
                && tree.pool.usage == usage_before
                && tree.pool.live_slots() == slots_before
                && tree.validate().is_ok();
            if !same {
                result.unchanged = false;
            }
            n += 1;
        }
        result.puts += 1;
    }
    result.nodes_created = tree.pool.usage.created;
    drop(tree);
    result.live_after_deinit = crate::alloc_count::stats().live() - live_before;
    result
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
