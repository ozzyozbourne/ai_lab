//! The tests of this chapter: the toolkit pointed at the tree.
//!
//! Passing tests print nothing; the numbers (seed, step, reproducer) are
//! printed by `cargo run` (scenario.rs).

use crate::alloc_count;
use crate::base_btree::{BTree, Bug};
use crate::base_insert::MAX_HEIGHT;
use crate::base_pool::OutOfNodes;
use crate::base_validate::{ValidateError, max_height};
use crate::coverage::{POINT_COUNT, Point};
use crate::fuzz::{self, Checks, Failure, KeyLayout, Kind, Step, Subject, Totals};
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
    assert_eq!(c.key_layout, KeyLayout::Spread);
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
    assert!(cases.iter().any(|c| c.fault_one_in == 1)); // faults in every put
    assert!(cases.iter().any(|c| !c.drain));
    // `KeyLayout::Spread` relies on it.
    assert!(cases.iter().all(|c| c.key_space.is_power_of_two()));
    for layout in KeyLayout::ALL {
        assert!(cases.iter().any(|c| c.key_layout == layout));
    }
}

#[test]
fn key_layouts_pinned_keys_strictly_increasing_never_max() {
    use KeyLayout::{Around2Pow32, Dense, Spread, Top};
    assert_eq!(Dense.key(64, 5), 5);
    assert_eq!(Around2Pow32.key(64, 0), (1 << 32) - 32); // 32 keys below 2^32 ...
    assert_eq!(Around2Pow32.key(64, 63), (1 << 32) + 31); // ... and 32 from it upwards
    assert_eq!(Spread.key(64, 3), 3 << 58);
    assert_eq!(Spread.key(256, 255), 255 << 56);
    assert_eq!(Spread.key(4, 4), u64::MAX); // one past the end saturates
    assert_eq!(Top.key(64, 0), u64::MAX - 64);
    assert_eq!(Top.key(64, 63), u64::MAX - 1); // the largest key ever used
    assert_eq!(Top.key(64, 64), u64::MAX); // only as an exclusive range bound
    for layout in KeyLayout::ALL {
        for key_space in [4, 16, 64, 256] {
            for k in 0..key_space {
                assert!(layout.key(key_space, k) < layout.key(key_space, k + 1));
            }
            assert!(layout.key(key_space, key_space - 1) < u64::MAX);
        }
    }
}

#[test]
fn generate_the_sweep_uses_keys_a_32_bit_or_signed_comparison_would_get_wrong() {
    // What the keys must offer for a magnitude bug to show (the reviewer's
    // mutant: `put` compares only the low 32 bits of the key):
    let mut small = false; // dense small keys, as before
    let mut above_32_bits = false;
    let mut same_low_half = false; // two different keys that agree in their low 32 bits
    let mut both_sides_of_2_32 = false;
    let mut both_sides_of_2_63 = false; // different sign if read as i64
    let mut near_max = false;
    for seed in 1..=SWEEP_SEEDS {
        let keys: Vec<u64> = fuzz::generate(fuzz::swarm(seed))
            .iter()
            .filter_map(|step| match step.op {
                Op::Put { key, .. } => Some(key),
                _ => None,
            })
            .collect();
        let lowest = *keys.iter().min().unwrap();
        let highest = *keys.iter().max().unwrap();
        same_low_half |= keys
            .windows(2)
            .any(|w| w[0] != w[1] && w[0] as u32 == w[1] as u32);
        small |= highest < 256;
        above_32_bits |= highest > u64::from(u32::MAX);
        both_sides_of_2_32 |= lowest < 1 << 32 && ((1 << 32)..(1 << 33)).contains(&highest);
        both_sides_of_2_63 |= lowest < 1 << 63 && highest >= 1 << 63;
        near_max |= highest >= u64::MAX - 2;
    }
    assert!(small && above_32_bits && same_low_half);
    assert!(both_sides_of_2_32 && both_sides_of_2_63 && near_max);
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
                faults += usize::from(step.fault);
            }
            Op::Delete { key } => {
                alive.remove(&key);
            }
            _ => assert!(!step.fault), // only puts allocate
        }
    }
    assert!(alive.is_empty());
    assert!(faults > 0);
}

#[test]
fn generate_ranges_also_come_empty_inverted_and_up_to_both_ends_of_u64() {
    // The operation stream alone only ever asks for [lo, hi) with lo < hi
    // between two keys of the case. A scan that stops on `key > hi - 1`
    // (overflow at hi = 0) passed every test until these shapes were
    // generated.
    let (mut ordinary, mut inverted, mut empty, mut hi_is_zero) = (0, 0, 0, 0);
    let (mut from_zero, mut to_max, mut everything) = (0, 0, 0);
    for seed in 1..=SWEEP_SEEDS {
        let case = fuzz::swarm(seed);
        for step in fuzz::generate(case) {
            let Op::Range { lo, hi } = step.op else {
                continue;
            };
            ordinary += usize::from(lo < hi && hi != u64::MAX);
            inverted += usize::from(lo > hi);
            empty += usize::from(lo == hi);
            hi_is_zero += usize::from(hi == 0);
            from_zero += usize::from(lo == 0 && case.key_layout != KeyLayout::Dense);
            to_max += usize::from(hi == u64::MAX && lo != 0);
            everything += usize::from(lo == 0 && hi == u64::MAX);
        }
    }
    for n in [inverted, empty, hi_is_zero, from_zero, to_max, everything] {
        assert!(n >= 20);
    }
    // Still the common case.
    assert!(ordinary > inverted + empty + from_zero + to_max + everything);
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
        // Faults reach deep reservations too: some failed put had already
        // taken three nodes or more. (With faults only at allocation 0, 1
        // or 2 a rollback that hands back at most two nodes passed.)
        assert!(totals.deepest_rollback >= 3);
    }
}

#[test]
fn range_empty_inverted_and_extreme_bounds_on_a_real_tree() {
    const MAX: u64 = u64::MAX;
    let keys = [0, 1, 5, 9, 1 << 32, 1 << 63, MAX - 1]; // three levels at M = 4
    let mut tree = BTree::new(4);
    for key in keys {
        tree.put(key, key).unwrap();
    }
    let cases = [
        (0, MAX, keys.len()),
        (0, 0, 0), // `hi - 1` would overflow here
        (5, 5, 0),
        (9, 1, 0), // inverted: empty, not "from 9 upward"
        (MAX, 0, 0),
        (MAX - 1, MAX, 1),
        (0, 1, 1),
        (1, (1 << 63) + 1, 5),
    ];
    for (lo, hi, want) in cases {
        let mut seen = 0;
        tree.range(lo, hi, |_, _| seen += 1);
        assert_eq!(seen, want, "range [{lo}, {hi})");
    }
    // The one key the fuzzer never uses, because no half-open range (not
    // even its own full scan of the oracle) can contain it.
    assert_eq!(tree.put(MAX, 7), Ok(None));
    assert_eq!(tree.get(MAX), Some(7));
    let mut widest = 0;
    tree.range(0, MAX, |_, _| widest += 1);
    assert_eq!(widest, keys.len()); // still without it
    tree.validate().unwrap();
    assert_eq!(tree.delete(MAX), Some(7));
    assert_eq!(tree.get(MAX), None);
    tree.validate().unwrap();
}

#[test]
fn the_height_bound_puts_path_array_is_as_long_as_the_tallest_tree_validate_accepts() {
    // `MAX_HEIGHT` cannot be reached by any test (64 levels need 2^64 keys),
    // so it is tied to chapter 03's formula instead: base_insert.rs does not
    // compile with a smaller constant, and `validate` asserts the formula on
    // every tree the fuzzer builds. Here: the formula is not just generous.
    for order in ORDERS {
        assert!(MAX_HEIGHT >= max_height(order, u64::MAX));
    }
    assert_eq!(MAX_HEIGHT, max_height(3, u64::MAX));
    // Ascending inserts at M = 3 leave every node at its minimum except on
    // the right edge: the tree is as tall as 2^h - 1 keys allow, whenever
    // the count is one of those numbers.
    let mut tree = BTree::new(3);
    let mut tight = 0;
    for key in 1..256 {
        tree.put(key, key).unwrap();
        tree.validate().unwrap(); // asserts height <= max_height(3, key)
        let height = tree.shape().height;
        assert!(height <= max_height(3, key));
        tight += usize::from(height == max_height(3, key));
    }
    assert!(tight > 0);
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
    let expected = [(191, 20, 5), (154, 68, 8), (71, 28, 51)];
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
fn fuzz_a_failed_put_that_keeps_a_reserved_node_or_marks_pool_usage_is_caught() {
    // Two test-only seams in the rollback of `put` (base_btree.rs, `Bug`).
    // Both leave the tree's shape and contents untouched, so only the
    // accounting checks can see them.
    for order in ORDERS {
        // The slab holds one slot more than the tree can reach. `usage` does
        // not show it (the rollback restores it), and neither does the
        // counting global allocator (the slab's Vec is dropped whole): only
        // `validate`'s count of occupied slots does. In Zig the same bug is
        // reported as a leak by the allocator wrapper.
        let subject = Subject {
            order,
            bug: Bug::RollbackLeaksNode,
        };
        let leaked = fuzz::hunt(subject, 1, SWEEP_SEEDS, checks(), None).unwrap();
        assert_eq!(leaked.failure.kind, Kind::OomChangedTree);
        // `created`, `destroyed` and `peak` count nodes that were never part of the tree.
        let subject = Subject {
            order,
            bug: Bug::RollbackKeepsUsage,
        };
        let counted = fuzz::hunt(subject, 1, SWEEP_SEEDS, checks(), None).unwrap();
        assert_eq!(counted.failure.kind, Kind::OomChangedTree);
        // The oracle comparison alone sees neither.
        let without_validate = Checks {
            validate: false,
            ..checks()
        };
        for bug in [Bug::RollbackLeaksNode, Bug::RollbackKeepsUsage] {
            let subject = Subject { order, bug };
            assert_eq!(
                fuzz::hunt(subject, 1, SWEEP_SEEDS, without_validate, None),
                None
            );
        }
    }
}

#[test]
fn validate_counts_the_occupied_slots_not_only_the_usage_counters() {
    // By hand what `Bug::RollbackLeaksNode` does: a slot is taken and the
    // counters are put back. `usage.live()` still equals the reachable nodes.
    let mut tree = BTree::new(4);
    for key in 1..=10 {
        tree.put(key, key).unwrap();
    }
    assert!(tree.validate().is_ok());
    let usage = tree.pool.usage;
    tree.pool.alloc(crate::base_node::Node::new(true)).unwrap();
    tree.pool.usage = usage;
    assert_eq!(tree.shape().nodes as u64, tree.pool.usage.live());
    assert_eq!(
        tree.validate().unwrap_err().error,
        ValidateError::NodeCountMismatch
    );
}

#[test]
fn step_prints_as_one_line_of_a_reproducer_also_the_line_of_the_trace_output() {
    let put = Step {
        op: Op::Put { key: 7, value: 70 },
        fault: true,
    };
    assert_eq!(
        put.to_string(),
        "put 7 = 70 (each node allocation fails once first)"
    );
    let range = Step {
        op: Op::Range { lo: 3, hi: 9 },
        fault: false,
    };
    assert_eq!(range.to_string(), "range [3, 9)");
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

/// True if some contiguous block of `steps` can be removed and the rest
/// still fails like `target`.
fn some_block_is_removable(subject: Subject, steps: &[Step], target: &Failure) -> bool {
    for start in 0..steps.len() {
        for end in start + 1..=steps.len() {
            if end - start == steps.len() {
                continue; // nothing left
            }
            let mut shorter = steps[..start].to_vec();
            shorter.extend_from_slice(&steps[end..]);
            if fuzz::replay(subject, &shorter, checks(), None).is_some_and(|f| f.same_kind(target))
            {
                return true;
            }
        }
    }
    false
}

#[test]
fn minimize_no_contiguous_block_of_steps_can_be_removed_from_the_result() {
    // The guarantee stated in minimize.rs, checked on the first failing
    // seeds of each variant (not only the hand-picked shortest run). A
    // minimiser whose chunk sizes only shrink fails this for 13 of these 60
    // runs: it leaves pairs of steps that can only be removed together.
    for bug in BUGS {
        let subject = Subject { order: 4, bug };
        let failing = (1..).filter_map(|seed| fuzz::hunt(subject, seed, 1, checks(), None));
        for found in failing.take(20) {
            let steps = fuzz::generate(found.case);
            let small = minimize(subject, &steps, found.failure, checks());
            let again = fuzz::replay(subject, &small.steps, checks(), None).unwrap();
            assert_eq!(again.step, small.steps.len() - 1);
            assert!(again.same_kind(&found.failure));
            assert!(!some_block_is_removable(
                subject,
                &small.steps,
                &found.failure
            ));
        }
    }
}

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
            assert!(!step.fault);
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
fn counting_allocator_delete_asks_for_no_node_and_gives_memory_back() {
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
    // ... but the heap was busy: every freed node dropped its Vec buffers.
    // (In Zig, delete makes no allocator call at all. Here a merge appends
    // to the left node's Vecs, which is allowed to reallocate; whether it
    // does depends on Vec's growth policy, so it is not asserted.)
    assert!(after.frees > before.frees);
    assert!(after.live_bytes < before.live_bytes);
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
