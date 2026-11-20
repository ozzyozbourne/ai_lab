//! The tests of this chapter: the toolkit pointed at the tree.
//!
//! Passing tests print nothing; the numbers (seed, step, reproducer) are
//! printed by `cargo run` (scenario.rs).

use crate::alloc_count;
use crate::base_btree::{BTree, Bug};
use crate::base_pool::OutOfNodes;
use crate::base_validate::ValidateError;
use crate::coverage::{POINT_COUNT, Point};
use crate::fuzz::{self, Checks, Failure, Kind, Step, Subject, Totals};
use crate::minimize::minimize;
use crate::ops::{Op, Weights};
use crate::scenario::{self, BUGS, HUNT_SEEDS, ORDERS, SWEEP_SEEDS};
use std::collections::BTreeSet;

fn checks() -> Checks {
    Checks::default()
}

// ---- the generator ---------------------------------------------------------

#[test]
fn swarm_one_seed_fixes_the_whole_case_pinned_same_numbers_in_zig() {
    let c = fuzz::swarm(1);
    assert_eq!(c.count, 256);
    assert_eq!(c.key_space, 64);
    assert_eq!(
        c.weights,
        Weights {
            put: 8,
            delete: 4,
            get: 4,
            range: 1
        }
    );
    assert_eq!(c.fault_one_in, 2);
    assert!(c.drain);
    assert_eq!(c.stream_seed, 11168034603498703870);
    assert_eq!(c.aux_seed, 8392123148533390784);
}

#[test]
fn swarm_the_seeds_really_differ_in_the_dimensions_that_matter() {
    let cases: Vec<_> = (1..=SWEEP_SEEDS).map(fuzz::swarm).collect();
    assert!(cases.iter().all(|c| c.weights.put > 0));
    assert!(cases.iter().any(|c| c.weights.delete == 0));
    assert!(cases.iter().any(|c| c.key_space == 4));
    assert!(cases.iter().any(|c| c.fault_one_in != 0));
    assert!(cases.iter().any(|c| !c.drain));
}

#[test]
fn generate_same_case_same_steps_and_a_drained_case_ends_with_no_key_alive() {
    let case = fuzz::swarm(1);
    let a = fuzz::generate(case);
    assert_eq!(a.len(), 294); // 256 generated + 38 drain deletes
    assert_eq!(a, fuzz::generate(case));

    let mut alive = BTreeSet::new();
    let mut faults = 0;
    for step in &a {
        match step.op {
            Op::Put { key, .. } => {
                alive.insert(key);
                faults += usize::from(step.fault.is_some());
            }
            Op::Delete { key } => {
                alive.remove(&key);
            }
            _ => assert_eq!(step.fault, None), // only puts allocate
        }
    }
    assert!(alive.is_empty());
    assert!(faults > 0);
}

// ---- the correct tree ------------------------------------------------------

#[test]
fn fuzz_the_correct_tree_passes_at_every_order_and_every_branch_was_reached() {
    for order in ORDERS {
        let mut totals = Totals::default();
        let found = fuzz::hunt(
            Subject::correct(order),
            1,
            SWEEP_SEEDS,
            checks(),
            Some(&mut totals),
        );
        assert_eq!(found, None);
        // The coverage assert: a green run that never split an interior node
        // or never rolled back a reservation has not tested those paths.
        assert_eq!(totals.coverage.first_missing(), None);
        assert!(totals.max_height >= 4);
        assert!(totals.injected_faults > 0);
    }
}

#[test]
fn fuzz_tiny_nodes_are_what_reaches_the_interior_cases() {
    // Same seeds, same operations, 31 keys per node: at most 256 distinct
    // keys never build a third level, so nothing ever happens to an
    // interior node.
    let mut totals = Totals::default();
    assert_eq!(
        fuzz::hunt(
            Subject::correct(32),
            1,
            SWEEP_SEEDS,
            checks(),
            Some(&mut totals)
        ),
        None
    );
    assert_eq!(totals.max_height, 2);
    for point in [
        Point::SplitInterior,
        Point::RootSplitInterior,
        Point::BorrowLeftInterior,
        Point::BorrowRightInterior,
        Point::MergeInterior,
    ] {
        assert_eq!(totals.coverage.count(point), 0);
    }
    assert_eq!(totals.coverage.reached(), POINT_COUNT - 5);
}

// ---- the broken trees ------------------------------------------------------

#[test]
fn fuzz_each_broken_variant_is_caught_at_every_order() {
    for order in ORDERS {
        let hunt = |bug| fuzz::hunt(Subject { order, bug }, 1, HUNT_SEEDS, checks(), None).unwrap();

        let wrong_value = hunt(Bug::SplitWrongValue);
        assert!(matches!(
            wrong_value.failure.kind,
            Kind::WrongResult | Kind::WrongContents
        ));

        let leak = hunt(Bug::MergeLeaksNode);
        assert_eq!(
            leak.failure.kind,
            Kind::Invariant(ValidateError::NodeCountMismatch)
        );

        let lost_child = hunt(Bug::BorrowForgetsChild);
        assert_eq!(
            lost_child.failure.kind,
            Kind::Invariant(ValidateError::MissingChild)
        );
        assert!(lost_child.failure.depth >= 1); // an interior node below the root
    }
}

#[test]
fn fuzz_seed_and_step_of_the_shortest_failing_run_as_printed_by_run() {
    let expected = [(191, 72, 4), (154, 68, 8), (74, 28, 51)];
    for (bug, (failing, seed, step)) in BUGS.into_iter().zip(expected) {
        let census = fuzz::hunt_shortest(Subject { order: 4, bug }, 1, HUNT_SEEDS, checks());
        let shortest = census.shortest.unwrap();
        assert_eq!(census.failing_seeds, failing);
        assert_eq!(shortest.case.seed, seed);
        assert_eq!(shortest.failure.step, step);
    }
}

#[test]
fn fuzz_each_family_of_checks_sees_a_bug_the_other_one_cannot() {
    // A leaked node: every answer is still right. Only validate (pool
    // accounting) notices.
    let subject = Subject {
        order: 4,
        bug: Bug::MergeLeaksNode,
    };
    let found = fuzz::hunt(subject, 1, HUNT_SEEDS, checks(), None).unwrap();
    let without_validate = Checks {
        validate: false,
        ..checks()
    };
    assert_eq!(
        fuzz::replay(subject, &fuzz::generate(found.case), without_validate, None),
        None
    );

    // A wrong value in a well-formed tree: validate has nothing to say.
    let subject = Subject {
        order: 4,
        bug: Bug::SplitWrongValue,
    };
    let found = fuzz::hunt(subject, 1, HUNT_SEEDS, checks(), None).unwrap();
    let without_model = Checks {
        model: false,
        ..checks()
    };
    assert_eq!(
        fuzz::replay(subject, &fuzz::generate(found.case), without_model, None),
        None
    );
}

#[test]
fn failure_prints_what_broke_and_where() {
    let located = Failure {
        step: 3,
        kind: Kind::Invariant(ValidateError::MissingChild),
        depth: 1,
        first_key: Some(9),
    };
    assert_eq!(
        located.to_string(),
        "invariant MissingChild at depth 1 (node starts with key 9)"
    );
    let whole_tree = Failure {
        step: 3,
        kind: Kind::Invariant(ValidateError::NodeCountMismatch),
        depth: 0,
        first_key: None,
    };
    assert_eq!(whole_tree.to_string(), "invariant NodeCountMismatch");
    assert!(located.same_kind(&Failure {
        step: 99,
        first_key: None,
        ..located
    }));
    assert!(!located.same_kind(&whole_tree));
}

// ---- minimisation ----------------------------------------------------------

#[test]
fn minimize_short_still_failing_the_same_way_and_1_minimal() {
    for (bug, want_len) in BUGS.into_iter().zip([5, 6, 11]) {
        let subject = Subject { order: 4, bug };
        let found = fuzz::hunt_shortest(subject, 1, HUNT_SEEDS, checks())
            .shortest
            .unwrap();
        let steps = fuzz::generate(found.case);
        let small = minimize(subject, &steps, found.failure, checks());

        assert_eq!(small.steps.len(), want_len);
        // It is a reproducer: replaying it fails at its last step, same kind.
        let again = fuzz::replay(subject, &small.steps, checks(), None).unwrap();
        assert_eq!(again.step, small.steps.len() - 1);
        assert!(again.same_kind(&found.failure));
        // The correct tree runs the same steps without complaint.
        assert_eq!(
            fuzz::replay(Subject::correct(4), &small.steps, checks(), None),
            None
        );
        // 1-minimal: take any single step away and this failure is gone.
        for skip in 0..small.steps.len() {
            let mut shorter = small.steps.clone();
            shorter.remove(skip);
            let f = fuzz::replay(subject, &shorter, checks(), None);
            assert!(f.is_none_or(|f| !f.same_kind(&found.failure)));
        }
        // Readable: keys renumbered from 1, the n-th put writes n, no faults.
        let mut puts = 0;
        for step in &small.steps {
            assert_eq!(step.fault, None);
            if let Op::Put { key, value } = step.op {
                puts += 1;
                assert_eq!(value, puts);
                assert!(key >= 1 && key <= 2 * small.steps.len() as u64); // ranks, not random numbers
            }
        }
    }
}

// ---- fault injection and allocation counting -------------------------------

const CANONICAL_KEYS: [u64; 12] = [10, 20, 5, 6, 12, 30, 7, 17, 3, 25, 1, 15];

#[test]
fn faults_a_sticky_failure_at_every_allocation_index_fails_cleanly() {
    // The counterpart of Zig's `std.testing.checkAllAllocationFailures`:
    // the n-th node allocation and every later one fail (`fail_after` stays
    // armed). The build must stop with `OutOfNodes`, leave a valid tree
    // behind, and leak nothing when the tree is dropped.
    let live_before = alloc_count::stats().live();
    let mut n = 0;
    loop {
        let mut tree = BTree::new(4);
        tree.pool.fail_after = Some(n);
        let result: Result<(), OutOfNodes> = CANONICAL_KEYS
            .into_iter()
            .try_for_each(|key| tree.put(key, key * 10).map(|_| ()));
        assert!(tree.validate().is_ok());
        if result.is_ok() {
            break;
        }
        n += 1;
    }
    assert_eq!(n, 5); // the canonical tree has 5 nodes: allocation indices 0..=4 can fail
    assert_eq!(alloc_count::stats().live(), live_before);
}

#[test]
fn faults_the_sweep_also_checks_that_the_tree_is_unchanged_and_usable() {
    let sweep = scenario::fault_sweep(4, 40);
    assert_eq!(sweep.puts, 40);
    assert_eq!(sweep.nodes_created, sweep.injected); // every allocation point failed once
    assert!(sweep.handed_back > 0); // some failures hit a half-made reservation
    assert!(sweep.unchanged);
    assert_eq!(sweep.live_after_deinit, 0);
}

#[test]
fn counting_allocator_delete_asks_for_no_node_but_does_touch_the_heap() {
    let mut tree = BTree::new(4);
    for key in 1..=40 {
        tree.put(key, key).unwrap();
    }
    let created = tree.pool.usage.created;
    let before = alloc_count::stats();
    tree.pool.fail_after = Some(0); // any node allocation from here on would fail
    for key in 1..=40 {
        assert_eq!(tree.delete(key), Some(key));
    }
    let after = alloc_count::stats();
    // The slab was never asked for a node ...
    assert_eq!(tree.pool.usage.created, created);
    assert_eq!(tree.pool.usage.live(), 0);
    // ... and every freed node dropped its Vec buffers.
    assert!(after.frees > before.frees);
    // Difference from Zig, where delete makes no allocator call at all: a
    // merge appends to the left node's Vecs, which may have to grow.
    let grew =
        (after.allocations - before.allocations) + (after.reallocations - before.reallocations);
    assert!(grew > 0);
}

#[test]
fn counting_allocator_a_replay_gives_back_everything_it_took() {
    let before = alloc_count::stats();
    let steps: Vec<Step> = fuzz::generate(fuzz::swarm(1));
    assert_eq!(
        fuzz::replay(Subject::correct(4), &steps, checks(), None),
        None
    );
    drop(steps);
    let after = alloc_count::stats();
    assert!(after.allocations > before.allocations);
    assert_eq!(after.live(), before.live());
    assert_eq!(after.live_bytes, before.live_bytes);
}
