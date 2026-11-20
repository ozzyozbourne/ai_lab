//! Tests of chapter 19, deterministic ones first.
//!
//!   1. single-threaded: every protocol against the oracle and against the
//!      other protocols; a full node table;
//!   2. the test hook on ONE thread: which latches an operation holds;
//!   3. the test hook with TWO OR MORE threads (probe.rs): one operation
//!      frozen, the others run one at a time, no sleeps;
//!   4. bounded stress with up to 4 threads, then validate and oracle.

use std::sync::Mutex;
use std::sync::atomic::Ordering;
use std::thread;

use crate::base_node::Kind;
use crate::dump::{dump_to_string, entries};
use crate::ops::{Config, Op, OpStream, Oracle, Weights};
use crate::prng::SplitMix64;
use crate::probe::{self, Actor, Gate, OpSpec, Outcome, Pause, ProbeError, value_of};
use crate::stress;
use crate::{CANONICAL, Event, NodeId, OutOfNodes, PROTOCOLS, Point, Protocol, Tree};

/// Hook for operations that run while NO other thread touches the tree.
/// Nobody else can hold a lock or latch then, so an operation that has to
/// wait would wait for something an earlier operation leaked, forever. The
/// hook hears about the wait before it starts and fails the test instead of
/// letting it hang.
fn never_waits(event: Event) {
    if event.point != Point::Blocked {
        return;
    }
    if event.node == NodeId::NIL {
        panic!(
            "an operation running alone must wait for the tree-wide lock: an earlier one leaked it"
        );
    }
    panic!(
        "an operation running alone must wait for the latch of #{}: an earlier one leaked it",
        event.node.index()
    );
}

fn canonical_tree(protocol: Protocol) -> Tree {
    let tree = Tree::new(4, protocol, 64);
    for key in CANONICAL {
        tree.put_hooked(key, value_of(key), Some(&never_waits))
            .unwrap();
    }
    tree
}

/// Compares the leaf chain with the oracle, entry by entry.
fn assert_same_contents(tree: &Tree, oracle: &Oracle) {
    let got = entries(tree);
    let expected = oracle.range(0, u64::MAX);
    assert_eq!(got.len(), expected.len());
    for (g, e) in got.iter().zip(expected) {
        assert_eq!((g.key, g.value), (e.key, e.value));
    }
}

// ------------------------------------------------------- 1. single-threaded

#[test]
fn canonical_keys_all_protocols_build_the_tree_of_chapter_07() {
    for protocol in PROTOCOLS {
        let tree = canonical_tree(protocol);
        tree.validate().unwrap();
        // Same handles and same shape as chapter 07's expected output (the
        // chain is singly linked here, hence `->`).
        assert_eq!(
            dump_to_string(&tree),
            "height 3, 12 keys, 8 nodes\n\
             \x20 level 0: #7[15]\n\
             \x20 level 1: #2[6 10] #6[20]\n\
             \x20 leaves : #0(1 3 5) -> #4(6 7) -> #1(10 12) -> #5(15 17) -> #3(20 25 30)\n"
        );
        assert_eq!(tree.get(12), Some(1200));
        assert_eq!(tree.get(13), None);
        assert_eq!(tree.put(12, 7), Ok(Some(1200))); // overwrite
        assert_eq!(tree.get(12), Some(7));
        assert_eq!(tree.len(), 12);
        assert!(tree.nothing_locked());
    }
}

#[test]
fn an_empty_tree_is_a_valid_tree() {
    for protocol in PROTOCOLS {
        let tree = Tree::new(4, protocol, 1);
        tree.validate().unwrap();
        assert_eq!(tree.get(1), None);
        assert_eq!(tree.height(), 1);
        assert!(tree.is_empty());
        assert_eq!(
            dump_to_string(&tree),
            "height 1, 0 keys, 1 nodes\n  leaves : #0()\n"
        );
    }
}

#[test]
fn model_test_every_protocol_against_the_oracle_orders_3_4_5_and_16() {
    for protocol in PROTOCOLS {
        for order in [3usize, 4, 5, 16] {
            let tree = Tree::new(order, protocol, 1024);
            let mut oracle = Oracle::new();
            let stream = OpStream::new(Config {
                seed: 100 + order as u64,
                count: 4000,
                key_space: 300,
                weights: Weights {
                    put: 3,
                    delete: 0,
                    get: 2,
                    range: 0,
                },
            });
            for (step, op) in stream.enumerate() {
                match op {
                    Op::Put { key, value } => {
                        let old = tree.put_hooked(key, value, Some(&never_waits));
                        assert_eq!(old, Ok(oracle.put(key, value)));
                    }
                    Op::Get { key } => {
                        assert_eq!(tree.get_hooked(key, Some(&never_waits)), oracle.get(key));
                    }
                    Op::Delete { .. } | Op::Range { .. } => unreachable!(),
                }
                if step % 97 == 0 {
                    tree.validate().unwrap();
                }
            }
            tree.validate().unwrap();
            assert_eq!(tree.len(), oracle.len());
            assert_same_contents(&tree, &oracle);
            assert!(tree.nothing_locked());
        }
    }
}

#[test]
fn the_three_protocols_produce_byte_identical_trees_for_the_same_operations() {
    for order in [3usize, 4, 7] {
        let mut reference: Option<String> = None;
        for protocol in PROTOCOLS {
            let tree = Tree::new(order, protocol, 1024);
            let mut rng = SplitMix64::new(order as u64);
            for _ in 0..1500 {
                let key = rng.below(400);
                tree.put(key, value_of(key)).unwrap();
            }
            let text = dump_to_string(&tree);
            match &reference {
                Some(r) => assert_eq!(*r, text),
                None => reference = Some(text),
            }
        }
    }
}

#[test]
fn out_of_nodes_for_every_table_size_the_failing_put_changes_nothing_and_releases_everything() {
    for protocol in PROTOCOLS {
        // The canonical tree needs 8 nodes; try every smaller table.
        for capacity in 1..8 {
            let tree = Tree::new(4, protocol, capacity);
            let mut inserted = 0;
            let mut failures = 0;
            for key in CANONICAL {
                let before = dump_to_string(&tree);
                match tree.put(key, value_of(key)) {
                    Ok(old) => {
                        assert_eq!(old, None);
                        inserted += 1;
                    }
                    Err(OutOfNodes) => {
                        failures += 1;
                        assert_eq!(dump_to_string(&tree), before);
                        // No lock or latch may survive the error path.
                        assert!(tree.nothing_locked());
                    }
                }
                tree.validate().unwrap();
            }
            assert!(failures > 0);
            assert_eq!(tree.len(), inserted);
            // Overwriting needs no node and still works on a full table.
            let some_key = CANONICAL[0];
            assert_eq!(tree.put(some_key, 1), Ok(Some(value_of(some_key))));
            assert_eq!(tree.get(some_key), Some(1));
        }
    }
}

// --------------------------------------------- 2. the hook on a single thread

/// Records, at chosen points of ONE operation, which nodes are latched
/// (`Tree::latched_nodes` tries to latch every node exclusively: that fails
/// exactly for the nodes the operation itself holds).
#[derive(Default)]
struct LatchSpy {
    /// Nodes latched when the descent ended (`AtLeaf`).
    at_leaf: Vec<u32>,
    /// Largest number of latches held right after acquiring one.
    max_held: usize,
}

/// Runs `op` with a spying hook and returns what the spy saw.
fn spy_on<R>(tree: &Tree, op: impl FnOnce(&(dyn Fn(Event) + Sync)) -> R) -> (R, LatchSpy) {
    // The hook must be `Sync`, hence a Mutex although only one thread runs.
    let spy = Mutex::new(LatchSpy::default());
    let hook = |event: Event| {
        if event.point != Point::Latched && event.point != Point::AtLeaf {
            return;
        }
        let held = tree.latched_nodes();
        let mut spy = spy.lock().unwrap();
        spy.max_held = spy.max_held.max(held.len());
        if event.point == Point::AtLeaf {
            spy.at_leaf = held;
        }
    };
    let result = op(&hook);
    (result, spy.into_inner().unwrap())
}

#[test]
fn latch_coupling_a_get_holds_at_most_two_latches_and_only_the_leaf_at_the_end() {
    let tree = canonical_tree(Protocol::LatchCoupling);
    for key in CANONICAL {
        let (got, spy) = spy_on(&tree, |hook| tree.get_hooked(key, Some(hook)));
        assert_eq!(got, Some(value_of(key)));
        assert_eq!(spy.max_held, 2); // parent + child, never three
        assert_eq!(spy.at_leaf.len(), 1);
    }
    assert!(tree.nothing_locked());
}

#[test]
fn latch_coupling_the_safe_node_rule_decides_which_latches_a_put_keeps() {
    let tree = canonical_tree(Protocol::LatchCoupling);
    //   #7[15]
    //   #2[6 10]                         #6[20]
    //   #0(1 3 5) #4(6 7) #1(10 12)      #5(15 17) #3(20 25 30)
    let put = |key: u64, value: u64| spy_on(&tree, |hook| tree.put_hooked(key, value, Some(hook)));

    // Leaf #1 has room: everything above it is released.
    let (_, spy) = put(11, value_of(11));
    assert_eq!(spy.at_leaf, [1]);
    // A writer couples too: it held #7 while it latched #2, and #2 while it
    // latched #1. Looking at a child and releasing the parent BEFORE the
    // child is latched would show up here as 1.
    assert_eq!(spy.max_held, 2);

    // Leaf #3 is full, its parent #6 has room: the split stops at #6, so #6
    // stays latched and the root does not.
    let (_, spy) = put(26, value_of(26));
    assert_eq!(spy.at_leaf, [3, 6]);
    assert_eq!(spy.max_held, 2); // #7+#6, then #6+#3: never three

    // Overwriting a key in a full leaf: the rule cannot know that no split
    // will happen, so it is as pessimistic as for a new key.
    let (old, spy) = put(3, 33);
    assert_eq!(old, Ok(Some(value_of(3))));
    assert_eq!(spy.at_leaf, [0, 2]);

    // Fill #2, then insert into the full leaf #0 below it: the run of full
    // nodes reaches up to the root's child, so the root stays latched too.
    tree.put(8, value_of(8)).unwrap();
    tree.put(9, value_of(9)).unwrap();
    assert_eq!(tree.table.read(NodeId::from_index(2)).len, 3);
    let (_, spy) = put(2, value_of(2));
    assert_eq!(spy.at_leaf, [0, 2, 7]);
    assert_eq!(spy.max_held, 3);

    tree.validate().unwrap();
    assert!(tree.nothing_locked());
}

#[test]
fn global_protocols_hold_the_tree_wide_lock_and_no_node_latch_between_steps() {
    for protocol in [Protocol::GlobalMutex, Protocol::GlobalRwLock] {
        let tree = canonical_tree(protocol);
        // Unlike Zig, plain.rs does take node latches (see its header), but
        // none is held when the hook runs, before the descent starts.
        let (_, spy) = spy_on(&tree, |hook| tree.put_hooked(26, value_of(26), Some(hook)));
        assert_eq!(spy.max_held, 0);
        // ... but the tree-wide lock is held at that point.
        let locked = Mutex::new(false);
        let hook = |event: Event| {
            if event.point == Point::AtLeaf {
                *locked.lock().unwrap() = !tree.nothing_locked();
            }
        };
        tree.get_hooked(26, Some(&hook));
        assert!(*locked.lock().unwrap());
        assert!(tree.nothing_locked());
    }
}

// ------------------------------------------------ 3. the hook with two threads

const DONE: Outcome = Outcome::Completed;
const WAITS: Outcome = Outcome::Blocked(NodeId::NIL);
fn waits_at(node: usize) -> Outcome {
    Outcome::Blocked(NodeId::from_index(node))
}

/// Rows of (B, expected under mutex, under rwlock, under latch coupling).
fn expect_probes(setup: &[u64], a: OpSpec, rows: &[(OpSpec, Outcome, Outcome, Outcome)]) {
    for &(b, mutex, rwlock, coupling) in rows {
        for (protocol, expected) in PROTOCOLS.into_iter().zip([mutex, rwlock, coupling]) {
            let tree = canonical_tree(protocol);
            for &key in setup {
                tree.put(key, value_of(key)).unwrap();
            }
            let outcome = probe::probe(&tree, a, Pause::at(Point::AtLeaf), b);
            assert_eq!(outcome, Ok(expected), "{protocol:?} A={a:?} B={b:?}");
            // Both operations ran to completion afterwards.
            tree.validate().unwrap();
            assert!(tree.nothing_locked());
            for op in [a, b] {
                if let OpSpec::Put(key) = op {
                    assert_eq!(tree.get(key), Some(value_of(key)));
                }
            }
        }
    }
}

#[test]
fn probe_what_a_frozen_reader_allows() {
    // A mutex stops everybody; a reader-writer lock lets readers through;
    // latch coupling also lets a writer through, unless it needs the very
    // leaf the reader is on.
    expect_probes(
        &[],
        OpSpec::Get(12),
        &[
            (OpSpec::Get(25), WAITS, DONE, DONE),
            (OpSpec::Get(10), WAITS, DONE, DONE),
            (OpSpec::Put(16), WAITS, WAITS, DONE),
            (OpSpec::Put(11), WAITS, WAITS, waits_at(1)),
        ],
    );
}

#[test]
fn probe_what_a_frozen_writer_allows() {
    // Leaf #1 has room: the writer holds only that leaf.
    expect_probes(
        &[],
        OpSpec::Put(11),
        &[
            (OpSpec::Get(25), WAITS, WAITS, DONE),
            (OpSpec::Get(12), WAITS, WAITS, waits_at(1)),
            (OpSpec::Put(16), WAITS, WAITS, DONE),
        ],
    );
    // Leaf #3 is full: its parent #6 stays latched, the subtree under #6 is
    // closed, the subtree under #2 is not.
    expect_probes(
        &[],
        OpSpec::Put(26),
        &[
            (OpSpec::Get(12), WAITS, WAITS, DONE),
            (OpSpec::Put(11), WAITS, WAITS, DONE),
            (OpSpec::Get(17), WAITS, WAITS, waits_at(6)),
        ],
    );
    // Full leaf under a full parent: the latches reach the root and latch
    // coupling is no better than a tree-wide lock.
    expect_probes(
        &[8, 9],
        OpSpec::Put(2),
        &[(OpSpec::Get(25), WAITS, WAITS, waits_at(7))],
    );
}

#[test]
fn probe_mid_descent_the_parent_is_still_latched_when_the_child_has_just_been_latched() {
    let tree = canonical_tree(Protocol::LatchCoupling);
    let after = |node: usize| Pause {
        point: Point::Latched,
        node: Some(NodeId::from_index(node)),
    };
    // Writer: put 26 has just latched #6. It has not looked at #6 yet, so it
    // still holds the root, and even a reader bound for #2 waits there.
    let outcome = probe::probe(&tree, OpSpec::Put(26), after(6), OpSpec::Get(12));
    assert_eq!(outcome, Ok(waits_at(7)));
    // Reader: get 12 has just latched leaf #1 and still holds #2 shared. A
    // put under #2 waits at #2; a reader passes; the root is free again.
    let behind_reader = |b: OpSpec| probe::probe(&tree, OpSpec::Get(12), after(1), b);
    assert_eq!(behind_reader(OpSpec::Put(7)), Ok(waits_at(2)));
    assert_eq!(behind_reader(OpSpec::Get(7)), Ok(DONE));
    assert_eq!(behind_reader(OpSpec::Put(16)), Ok(DONE));
    tree.validate().unwrap();
    assert!(tree.nothing_locked());
}

#[test]
fn convoy_a_reader_that_waits_keeps_the_root_and_a_writer_bound_elsewhere_waits_behind_it() {
    let tree = canonical_tree(Protocol::LatchCoupling);
    // A = put 26 is frozen holding #6 and #3 (exclusive). With two threads,
    // `put 11` finishes next to it (see probe_what_a_frozen_writer_allows).
    let outcomes = probe::convoy(
        &tree,
        OpSpec::Put(26),
        Pause::at(Point::AtLeaf),
        &[
            OpSpec::Get(17), // B: waits at #6, HOLDING #7 shared
            OpSpec::Get(12), // C: shares #7 with B and gets through
            OpSpec::Put(11), // D: needs #7 exclusive; B is in its way, not A
        ],
    );
    assert_eq!(outcomes, Ok(vec![waits_at(6), DONE, waits_at(7)]));
    tree.validate().unwrap();
    assert!(tree.nothing_locked());
    for key in [26, 11] {
        assert_eq!(tree.get(key), Some(value_of(key)));
    }
}

#[test]
fn convoy_one_reader_stalled_on_a_leaf_closes_the_tree_for_writers_three_waits_deep() {
    let tree = canonical_tree(Protocol::LatchCoupling);
    // A = get 25 is frozen on leaf #3 with one SHARED latch.
    let outcomes = probe::convoy(
        &tree,
        OpSpec::Get(25),
        Pause::at(Point::AtLeaf),
        &[
            OpSpec::Put(26), // waits at #3 for A, holding #6 exclusive
            OpSpec::Get(17), // waits at #6 for the put, holding #7 shared
            OpSpec::Get(12), // shares #7 and gets through
            OpSpec::Put(11), // waits at #7 for the get 17
        ],
    );
    assert_eq!(
        outcomes,
        Ok(vec![waits_at(3), waits_at(6), DONE, waits_at(7)])
    );
    tree.validate().unwrap();
    assert!(tree.nothing_locked());
    for key in [26, 11] {
        assert_eq!(tree.get(key), Some(value_of(key)));
    }
}

#[test]
fn probe_reports_a_pause_point_that_is_never_reached() {
    let tree = canonical_tree(Protocol::GlobalMutex);
    // A global protocol never emits `RootLoaded`.
    let outcome = probe::probe(
        &tree,
        OpSpec::Get(1),
        Pause::at(Point::RootLoaded),
        OpSpec::Get(2),
    );
    assert_eq!(outcome, Err(ProbeError::PauseNotReached));
    assert!(tree.nothing_locked());
}

#[test]
fn latch_coupling_a_reader_that_latched_a_replaced_root_starts_again() {
    let tree = Tree::new(4, Protocol::LatchCoupling, 16);
    for key in [10, 20, 5] {
        tree.put(key, value_of(key)).unwrap();
    }

    // The reader has read "root = #0" and holds nothing.
    let reader = Actor::new(&tree, OpSpec::Get(20), Some(Pause::at(Point::RootLoaded)));
    let result = thread::scope(|scope| {
        let handle = scope.spawn(|| reader.run());
        reader.wait_settled();
        let frozen = reader.frozen();
        // The root splits: #0 keeps (5 6); key 20 moves to the new leaf #1.
        let put = tree.put(6, value_of(6));
        let root_after = tree.root();
        let restarts_before = tree.stats.root_restarts.load(Ordering::Relaxed);
        // Release and join BEFORE asserting: a panic with the reader still
        // frozen would hang the scope instead of failing the test.
        reader.release();
        let result = handle.join().unwrap();
        assert!(frozen);
        assert_eq!(put, Ok(None));
        assert_eq!(root_after.index(), 2);
        assert_eq!(restarts_before, 0);
        result
    });
    // Without the second look at the root id the reader would search #0,
    // which no longer holds 20, and answer "not found".
    assert_eq!(result, Ok(Some(2000)));
    assert_eq!(tree.stats.root_restarts.load(Ordering::Relaxed), 1);
    assert!(tree.nothing_locked());
}

#[test]
fn latch_coupling_a_writer_that_latched_a_replaced_root_starts_again() {
    let tree = Tree::new(4, Protocol::LatchCoupling, 16);
    for key in [10, 20, 5] {
        tree.put(key, value_of(key)).unwrap();
    }

    // The writer has read "root = #0" and holds nothing.
    let writer = Actor::new(&tree, OpSpec::Put(30), Some(Pause::at(Point::RootLoaded)));
    let result = thread::scope(|scope| {
        let handle = scope.spawn(|| writer.run());
        writer.wait_settled();
        let frozen = writer.frozen();
        // The root splits: #0 keeps (5 6); (10 20) move to the new leaf #1.
        let put = tree.put(6, value_of(6));
        let root_after = tree.root();
        // Release and join BEFORE asserting (see the reader's test above).
        writer.release();
        let result = handle.join().unwrap();
        assert!(frozen);
        assert_eq!(put, Ok(None));
        assert_eq!(root_after.index(), 2);
        result
    });
    assert_eq!(result, Ok(None));
    assert_eq!(tree.stats.root_restarts.load(Ordering::Relaxed), 1);
    // First of all: a latch left on the old root would make `validate` and
    // `dump` below wait forever instead of failing.
    assert!(tree.nothing_locked());
    tree.validate().unwrap();
    // Without the second look the writer would put 30 into #0, the LEFT
    // leaf, to the left of separator 10: no search would ever find it.
    assert_eq!(tree.get(30), Some(3000));
    assert_eq!(
        dump_to_string(&tree),
        "height 2, 5 keys, 3 nodes\n\
         \x20 level 0: #2[10]\n\
         \x20 leaves : #0(5 6) -> #1(10 20 30)\n"
    );
}

#[test]
fn a_new_root_is_complete_before_it_is_published() {
    for protocol in PROTOCOLS {
        let tree = Tree::new(4, protocol, 16);
        for key in [10, 20, 5] {
            tree.put(key, value_of(key)).unwrap();
        }

        // put 6 splits the root leaf #0 and is frozen with the new root #2
        // built but not yet published.
        let writer = Actor::new(&tree, OpSpec::Put(6), Some(Pause::at(Point::RootBuilt)));
        let new_root_id = NodeId::from_index(2);
        let (frozen, published, keys, children, result) = thread::scope(|scope| {
            let handle = scope.spawn(|| writer.run());
            writer.wait_settled();
            let frozen = writer.frozen();
            // Read while the writer is frozen. Nobody holds the new node's
            // latch: it is not reachable yet.
            let published = tree.root();
            let (keys, children) = {
                let node = tree.table.read(new_root_id);
                let children = match &node.kind {
                    Kind::Internal(internal) => internal.children[..2].to_vec(),
                    Kind::Leaf(_) => Vec::new(),
                };
                (node.key_slice().to_vec(), children)
            };
            writer.release();
            (frozen, published, keys, children, handle.join().unwrap())
        });

        assert!(frozen, "{protocol:?}");
        assert_eq!(published.index(), 0); // still the old root
        assert_eq!(keys, [10]); //           and #2 is finished
        assert_eq!(children, [NodeId::from_index(0), NodeId::from_index(1)]);
        assert_eq!(result, Ok(None));
        assert_eq!(tree.root(), new_root_id);
        tree.validate().unwrap();
        assert!(tree.nothing_locked());
    }
}

#[test]
fn a_thread_waiting_for_the_old_roots_latch_starts_again_when_the_root_is_replaced() {
    for b_op in [OpSpec::Get(20), OpSpec::Put(30)] {
        let tree = Tree::new(4, Protocol::LatchCoupling, 16);
        for key in [10, 20, 5] {
            tree.put(key, value_of(key)).unwrap();
        }
        // A = put 6 is frozen with the new root #2 built but not published.
        // It must still hold the old root #0 exclusively: a writer keeps its
        // latches until the last node is written. B reads "root = #0" and so
        // has to WAIT at #0. (The two tests above freeze the thread before
        // it asks for the latch; here it is already in the queue.)
        let outcome = probe::probe(&tree, OpSpec::Put(6), Pause::at(Point::RootBuilt), b_op);
        assert_eq!(outcome, Ok(waits_at(0)), "{b_op:?}");
        // When B gets #0 at last it is no longer the root: one restart. A
        // B that looked at the root id only BEFORE it queued would go on
        // into #0, the left half, and miss 20 (or misplace 30).
        assert_eq!(tree.stats.root_restarts.load(Ordering::Relaxed), 1);
        assert!(tree.nothing_locked());
        tree.validate().unwrap();
        assert_eq!(tree.get(20), Some(2000));
        if let OpSpec::Put(key) = b_op {
            assert_eq!(tree.get(key), Some(value_of(key)));
        }
    }
}

/// A `get` that its test stops three times: when it has read the root id,
/// when it has latched that node, and at the first event after that.
struct SteppedGet<'t> {
    tree: &'t Tree,
    key: u64,
    /// `at[i]` is set by the reader when it reaches stop i; it then waits
    /// for `go[i]`.
    at: [Gate; 3],
    go: [Gate; 3],
    /// Number of stops so far, and the event of the third stop.
    seen: Mutex<(usize, Option<Event>)>,
}

impl<'t> SteppedGet<'t> {
    fn new(tree: &'t Tree, key: u64) -> SteppedGet<'t> {
        SteppedGet {
            tree,
            key,
            at: Default::default(),
            go: Default::default(),
            seen: Mutex::new((0, None)),
        }
    }

    fn on_event(&self, event: Event) {
        let i = {
            let mut seen = self.seen.lock().unwrap();
            let wanted = match seen.0 {
                0 => Some(Point::RootLoaded),
                1 => Some(Point::Latched),
                2 => None, // whatever comes first
                _ => return,
            };
            if wanted.is_some_and(|point| point != event.point) {
                return;
            }
            if seen.0 == 2 {
                seen.1 = Some(event);
            }
            seen.0 += 1;
            seen.0 - 1
        };
        self.at[i].set();
        self.go[i].wait();
    }

    fn run(&self) -> Option<u64> {
        let hook = |event: Event| self.on_event(event);
        self.tree.get_hooked(self.key, Some(&hook))
    }

    /// Lets the reader run from stop `i` to the next one.
    fn step(&self, i: usize) {
        self.go[i].set();
        if let Some(next) = self.at.get(i + 1) {
            next.wait();
        }
    }

    fn third(&self) -> Option<Event> {
        self.seen.lock().unwrap().1
    }
}

#[test]
fn latch_order_at_the_root_a_restart_lets_go_of_the_old_root_before_it_asks_for_the_new_one() {
    let tree = Tree::new(4, Protocol::LatchCoupling, 16);
    for key in [10, 20, 5] {
        tree.put(key, value_of(key)).unwrap();
    }

    let reader = SteppedGet::new(&tree, 20);
    let writer = Actor::new(&tree, OpSpec::Put(7), None);
    let (split, stale, third, held, writer_blocked_at, got) = thread::scope(|scope| {
        let reader_thread = scope.spawn(|| reader.run());
        reader.at[0].wait(); // the reader has read "root = #0"
        let split = tree.put(6, value_of(6)); // the root is #2 now, #0 its left child
        reader.step(0); // the reader holds #0 (shared) and has not looked again
        let stale = tree.latched_nodes();
        reader.step(1); // its next event, whatever it is
        // The reader is frozen again. It must hold NOTHING: #0 is below the
        // root now, and asking for #2 while holding #0 would be a latch
        // request going UP the tree. A writer that holds #2 and wants #0
        // goes down. The two would wait for each other forever.
        let third = reader.third();
        let held = tree.latched_nodes();
        // Such a writer, while the reader is frozen: it must get through.
        // If the reader kept a latch, the writer reports that it is stuck,
        // which ends this wait; nothing here can hang.
        let writer_thread = scope.spawn(|| writer.run());
        writer.wait_settled();
        let writer_blocked_at = writer.blocked_at();
        // Let everybody finish before the first assertion.
        reader.step(2);
        let got = reader_thread.join().unwrap();
        writer_thread.join().unwrap().unwrap();
        (split, stale, third, held, writer_blocked_at, got)
    });

    assert_eq!(split, Ok(None));
    assert_eq!(stale, [0]);
    let new_root = NodeId::from_index(2);
    assert_eq!(
        third.map(|e| (e.point, e.node)),
        Some((Point::RootLoaded, new_root))
    );
    assert_eq!(held, [0u32; 0]);
    assert_eq!(writer_blocked_at, None);
    assert_eq!(tree.stats.root_restarts.load(Ordering::Relaxed), 1);
    assert_eq!(got, Some(2000));
    assert!(tree.nothing_locked());
    tree.validate().unwrap();
    assert_eq!(tree.get(7), Some(700));
}

// ------------------------------------------------------------------ 4. stress

fn stress_once(protocol: Protocol, config: stress::Config, node_capacity: u32) -> stress::Report {
    let tree = Tree::new(4, protocol, node_capacity);
    let report = stress::run(&tree, config);
    assert!(tree.nothing_locked());
    report
}

#[test]
fn stress_4_threads_disjoint_and_overlapping_keys_every_protocol() {
    for protocol in PROTOCOLS {
        for overlapping in [false, true] {
            for seed in [1, 2] {
                let config = stress::Config {
                    threads: 4,
                    ops_per_thread: 4000,
                    seed,
                    key_space: if overlapping { 1500 } else { 400 },
                    overlapping,
                };
                let r = stress_once(protocol, config, config.node_capacity());
                assert!(r.valid);
                assert_eq!(r.mismatches, 0);
                assert_eq!(r.lost, 0);
                assert_eq!(r.failed, 0);
                assert_eq!(r.keys, r.expected_keys);
                // Every key was inserted exactly once, whoever got there first.
                assert_eq!(r.fresh, r.expected_keys);
                assert!(r.ok());
            }
        }
    }
}

#[test]
fn stress_a_hot_spot_few_keys_constant_overwrites_and_root_splits_early_on() {
    for protocol in PROTOCOLS {
        let config = stress::Config {
            threads: 4,
            ops_per_thread: 3000,
            seed: 7,
            key_space: 24,
            overlapping: true,
        };
        let r = stress_once(protocol, config, config.node_capacity());
        assert!(r.ok(), "{protocol:?}: {r:?}");
    }
}

#[test]
fn stress_the_node_table_runs_out_under_concurrency_and_the_tree_stays_valid() {
    for protocol in PROTOCOLS {
        let config = stress::Config {
            threads: 4,
            ops_per_thread: 2000,
            seed: 3,
            key_space: 5000,
            overlapping: true,
        };
        // 40 nodes of order 4 hold at most 120 keys: most puts must fail.
        let r = stress_once(protocol, config, 40);
        assert!(r.failed > 0);
        assert!(r.valid);
        // Only successful puts are logged, so the oracle still applies.
        assert_eq!(r.mismatches, 0);
        assert_eq!(r.lost, 0);
        assert_eq!(r.keys, r.expected_keys);
        assert_eq!(r.fresh, r.expected_keys);
    }
}
