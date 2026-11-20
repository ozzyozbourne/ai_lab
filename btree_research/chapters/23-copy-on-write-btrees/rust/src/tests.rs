//! Tests of the whole database: path copying, snapshots, deferred reuse,
//! abort, the metapage, seeded model tests with snapshots, the page budget
//! (Rust's stand-in for allocation failure), and proof that `validate`
//! catches corruption.

use crate::base_node::PageId;
use crate::db::{Db, NoValidMeta, Snapshot};
use crate::dump;
use crate::meta::Meta;
use crate::ops::{Config, Entry, Op, OpStream, Oracle, Weights};
use crate::read::View;
use crate::txn::TxnError;
use crate::validate::Violation;

const CANONICAL: [u64; 12] = [10, 20, 5, 6, 12, 30, 7, 17, 3, 25, 1, 15];
const SORTED: [u64; 12] = [1, 3, 5, 6, 7, 10, 12, 15, 17, 20, 25, 30];
const MAX_KEY: u64 = u64::MAX;

fn build_canonical() -> Db {
    let mut db = Db::new(4);
    for k in CANONICAL {
        db.put(k, k * 100).unwrap();
    }
    db
}

fn dump_string(view: View<'_>, txn_id: u64) -> String {
    let mut out = Vec::new();
    dump::dump(view, txn_id, &mut out).unwrap();
    String::from_utf8(out).unwrap()
}

fn keys(view: View<'_>) -> Vec<u64> {
    view.range(0, MAX_KEY).map(|e| e.key).collect()
}

fn entries(view: View<'_>, lo: u64, hi: u64) -> Vec<Entry> {
    view.range(lo, hi)
        .map(|e| Entry {
            key: e.key,
            value: e.value,
        })
        .collect()
}

fn reachable(db: &Db, view: View<'_>) -> Vec<bool> {
    let mut marks = vec![false; db.store.page_count()];
    dump::mark_reachable(view, &mut marks);
    marks
}

const CANONICAL_DUMP: &str = "\
txn 12: root #9, height 3, 12 keys
  level 0: #9[15]
  level 1: #4[6 10] #8[20]
  leaves : #3(1 3 5) #6(6 7) #0(10 12) | #7(15 17) #1(20 25 30)
";

// ------------------------------------------------------ fixed scenarios

#[test]
fn canonical_example_has_the_shape_shown_in_the_readme() {
    let db = build_canonical();
    db.validate().unwrap();
    assert_eq!(dump_string(db.view(), db.current.txn_id), CANONICAL_DUMP);
    for k in CANONICAL {
        assert_eq!(db.get(k), Some(k * 100));
    }
    assert_eq!(db.get(13), None);
}

#[test]
fn a_put_copies_exactly_the_root_to_leaf_path_and_shares_the_rest() {
    let mut db = build_canonical();
    let snap = db.snapshot();

    let mut txn = db.begin();
    txn.put(13, 1300).unwrap();
    let info = txn.commit().unwrap();
    assert_eq!(info.copied, 3); // height 3: root, internal, leaf
    assert_eq!(info.freed, 3);
    assert_eq!(info.released, 0); // the snapshot still needs them

    let old = reachable(&db, snap.view(&db));
    let new = reachable(&db, db.view());
    let count =
        |f: fn(bool, bool) -> bool| old.iter().zip(&new).filter(|&(&o, &n)| f(o, n)).count();
    assert_eq!(count(|o, n| o && n), 5); // 8 pages minus the path of 3
    assert_eq!(count(|o, n| o && !n), 3);
    assert_eq!(count(|o, n| n && !o), 3);

    // The old tree is byte for byte what it was.
    assert_eq!(dump_string(snap.view(&db), snap.id), CANONICAL_DUMP);
    db.validate().unwrap();
    db.release(snap);
    db.validate().unwrap();
}

#[test]
fn a_snapshot_keeps_reading_its_own_version_across_later_commits() {
    let mut db = build_canonical();
    let snap = db.snapshot();

    db.put(13, 1300).unwrap();
    db.put(10, 1).unwrap(); // overwrite
    db.delete(5).unwrap();
    for k in 40..80 {
        db.put(k, k).unwrap();
    }
    for k in CANONICAL {
        db.delete(k).unwrap();
    }
    db.validate().unwrap();

    assert_eq!(snap.view(&db).get(13), None);
    assert_eq!(snap.view(&db).get(10), Some(1000));
    assert_eq!(snap.view(&db).get(5), Some(500));
    assert_eq!(keys(snap.view(&db)), SORTED);
    assert_eq!(db.get(10), None);
    assert_eq!(db.len(), 41);
    db.release(snap);
    db.validate().unwrap();
    assert!(db.pending.is_empty());
}

#[test]
fn freed_pages_are_reused_only_after_the_snapshots_that_need_them_are_gone() {
    let mut db = build_canonical();

    // Without a snapshot the pages a commit replaces are free right away,
    // and the store stops growing.
    // (One warm-up commit: a path of 3 needs 3 free pages, the build left 2.)
    db.put(10, 0).unwrap();
    let pages_before = db.store.page_count();
    for i in 0..20 {
        db.put(10, i).unwrap();
    }
    assert_eq!(db.store.page_count(), pages_before);
    assert!(db.pending.is_empty());

    // With a snapshot nothing it might reach is reused: the store grows.
    let snap = db.snapshot();
    let second = db.retain(snap);
    for i in 0..20 {
        db.put(10, i).unwrap();
    }
    assert!(db.store.page_count() > pages_before);
    assert_eq!(db.pending.len(), 60); // 20 commits x path of 3
    db.validate().unwrap();

    // Refcount: the root stays pinned until the last handle is released.
    assert_eq!(db.release(snap), 0);
    assert_eq!(db.pending.len(), 60);
    assert_eq!(db.release(second), 60);
    assert!(db.pending.is_empty());
    db.validate().unwrap();

    let pages_after = db.store.page_count();
    for i in 0..20 {
        db.put(10, i).unwrap();
    }
    assert_eq!(db.store.page_count(), pages_after);
}

#[test]
fn the_oldest_snapshot_holds_back_every_later_free_a_newer_one_does_not() {
    let mut db = build_canonical();

    let old = db.snapshot(); // txn 12
    db.put(13, 1300).unwrap(); // txn 13 frees 3 pages
    let young = db.snapshot(); // txn 13
    db.put(14, 1400).unwrap(); // txn 14 frees 3 pages
    assert_eq!(db.pending.len(), 6);

    // Releasing the YOUNGER snapshot frees nothing: the pages freed by txn
    // 14 are only needed by it, but the rule is "older than T", and the
    // snapshot of txn 12 is older than 14.
    assert_eq!(db.release(young), 0);
    db.validate().unwrap();
    assert_eq!(db.release(old), 6);
    db.validate().unwrap();
}

#[test]
fn abort_leaves_the_store_the_meta_slots_and_the_free_list_untouched() {
    let mut db = build_canonical();
    let meta_before = db.store.meta_slots;
    let free_before = db.store.free.clone();
    let pages_before = db.store.page_count();

    let mut txn = db.begin();
    for k in 100..140 {
        txn.put(k, k).unwrap();
    }
    txn.delete(10).unwrap();
    assert_eq!(txn.view().count, 51);
    assert_eq!(txn.committed().get(100), None); // not visible outside
    txn.abort();

    assert_eq!(db.store.meta_slots, meta_before);
    assert_eq!(db.store.free, free_before);
    assert_eq!(db.store.page_count(), pages_before);
    assert_eq!(db.get(10), Some(1000));
    assert_eq!(db.len(), 12);
    db.validate().unwrap();

    // Going out of scope is an abort too.
    {
        let mut txn = db.begin();
        txn.put(500, 5).unwrap();
    }
    assert_eq!(db.get(500), None);
    assert_eq!(db.store.free, free_before);
    assert_eq!(db.stats.aborts, 2);
    db.validate().unwrap();
}

#[test]
fn a_transaction_copies_a_page_at_most_once_and_reads_its_own_writes() {
    let mut db = build_canonical();

    let mut txn = db.begin();
    // Three overwrites in the same leaf: one path copy, not three.
    txn.put(1, 11).unwrap();
    txn.put(3, 33).unwrap();
    txn.put(5, 55).unwrap();
    assert_eq!(txn.info().copied, 3);
    assert_eq!(txn.get(3), Some(33));
    assert_eq!(txn.committed().get(3), Some(300));
    let info = txn.commit().unwrap();
    assert_eq!(info.txn_id, 13); // one commit, one new root
    assert_eq!(db.get(3), Some(33));
    db.validate().unwrap();

    // A transaction that changes nothing publishes nothing.
    let mut idle = db.begin();
    assert_eq!(idle.delete(999), Ok(None));
    assert_eq!(idle.commit().unwrap().txn_id, 0);
    assert_eq!(db.current.txn_id, 13);
    assert_eq!(db.stats.aborts, 0);
}

#[test]
fn deleting_everything_returns_to_the_empty_tree_and_all_pages_are_reusable() {
    let mut db = build_canonical();
    for k in CANONICAL {
        assert_eq!(db.delete(k), Ok(Some(k * 100)));
        db.validate().unwrap();
    }
    assert!(db.current.root.is_nil());
    assert!(db.is_empty());
    assert_eq!(db.store.free.len(), db.store.page_count());
    assert_eq!(db.get(10), None);
    assert_eq!(db.range(0, MAX_KEY).next(), None);
    db.put(7, 70).unwrap();
    assert_eq!(db.get(7), Some(70));
    db.validate().unwrap();
}

#[test]
fn range_uses_the_stack_to_cross_leaf_and_subtree_boundaries() {
    let db = build_canonical();
    let mut it = db.range(7, 21); // starts mid-leaf, crosses the root separator 15
    for k in [7, 10, 12, 15, 17, 20] {
        assert_eq!(it.next().unwrap().key, k);
    }
    assert_eq!(it.next(), None);
    assert_eq!(it.next(), None); // stays finished
    assert_eq!(db.range(31, 99).next(), None);
    assert_eq!(db.range(8, 10).next(), None); // nothing in [8, 10)
}

// ---------------------------------------------------------- the metapage

#[test]
fn commits_alternate_between_the_meta_slots_a_torn_slot_falls_back_one_commit() {
    let mut db = Db::new(4);
    let mut oracle = Oracle::new();

    for i in 0..60u64 {
        let key = (i * 37) % 50;
        let previous = oracle.clone(); // content one commit ago
        let id_before = db.current.txn_id;
        if i % 3 == 2 {
            db.delete(key).unwrap();
            oracle.delete(key);
        } else {
            db.put(key, i).unwrap();
            oracle.put(key, i);
        }
        let id = db.current.txn_id;
        if id == id_before {
            continue; // deleting a missing key commits nothing
        }
        let slot = |txn: u64| {
            Meta::decode(&db.store.meta_slots[(txn % 2) as usize])
                .unwrap()
                .txn_id
        };
        assert_eq!(slot(id), id);
        assert_eq!(slot(id - 1), id - 1);

        if i % 4 == 3 {
            // The meta write of this commit was torn: after a restart the
            // previous commit must be complete, although this commit already
            // reused pages (only pages the previous root could not reach).
            db.store.meta_slots[(id % 2) as usize][(i % 32) as usize] ^= 0x01;
            db.reopen().unwrap();
            assert_eq!(db.current.txn_id, id - 1);
            db.validate().unwrap();
            assert_eq!(entries(db.view(), 0, MAX_KEY), previous.range(0, MAX_KEY));
            oracle = previous;
        } else if i % 4 == 1 {
            db.reopen().unwrap(); // a clean restart changes nothing
            assert_eq!(db.current.txn_id, id);
            db.validate().unwrap();
            assert_eq!(entries(db.view(), 0, MAX_KEY), oracle.range(0, MAX_KEY));
        }
    }
    db.store.meta_slots[0][0] ^= 1;
    db.store.meta_slots[1][0] ^= 1;
    assert_eq!(db.reopen(), Err(NoValidMeta));
}

// ---------------------------------------------------------- model tests

struct Held {
    snap: Snapshot,
    saved: Vec<Entry>,
}

fn config(seed: u64, count: u64, key_space: u64) -> Config {
    Config {
        seed,
        count,
        key_space,
        weights: Weights::default(),
    }
}

fn model_with_snapshots(order: usize, seed: u64, count: u64, key_space: u64) {
    let mut db = Db::new(order);
    let mut oracle = Oracle::new();
    let mut held: Vec<Held> = Vec::new();

    for (i, op) in OpStream::new(config(seed, count, key_space)).enumerate() {
        match op {
            Op::Put { key, value } => {
                assert_eq!(db.put(key, value).unwrap(), oracle.put(key, value))
            }
            Op::Delete { key } => assert_eq!(db.delete(key).unwrap(), oracle.delete(key)),
            Op::Get { key } => assert_eq!(db.get(key), oracle.get(key)),
            Op::Range { lo, hi } => assert_eq!(entries(db.view(), lo, hi), oracle.range(lo, hi)),
        }
        assert_eq!(db.len(), oracle.len() as u64);

        if i % 17 == 0 {
            // Take a snapshot and save what the oracle holds right now.
            held.push(Held {
                snap: db.snapshot(),
                saved: oracle.range(0, MAX_KEY).to_vec(),
            });
        }
        if i % 29 == 28 && !held.is_empty() {
            // Release one: sometimes the oldest, sometimes one in the middle.
            let h = held.remove((i / 29) % held.len());
            db.release(h.snap);
        }
        if i % 11 == 0 {
            db.validate().unwrap();
            for h in &held {
                assert_eq!(h.snap.count, h.saved.len() as u64);
                assert_eq!(entries(h.snap.view(&db), 0, MAX_KEY), h.saved);
            }
        }
    }
    while let Some(h) = held.pop() {
        db.release(h.snap);
    }
    db.validate().unwrap();
    // With no reader left, every page is either in the tree or free.
    assert!(db.pending.is_empty());
}

#[test]
fn model_one_transaction_per_write_snapshots_compared_with_saved_oracle_copies() {
    for order in [3, 4, 5, 8, 16] {
        model_with_snapshots(order, 1000 + order as u64, 4000, 150);
    }
    model_with_snapshots(4, 7, 2000, 12); // tiny key space: empties often
}

#[test]
fn model_multi_write_transactions_some_aborted() {
    for order in [3usize, 4, 6] {
        let mut db = Db::new(order);
        let mut oracle = Oracle::new();
        let mut stream = OpStream::new(config(99 + order as u64, 6000, 120));
        let mut done = false;
        let mut batch = 0;
        while !done {
            let saved = oracle.clone(); // oracle at txn begin
            let before = db.current;

            let mut txn = db.begin();
            for _ in 0..1 + batch % 7 {
                let Some(op) = stream.next() else {
                    done = true;
                    break;
                };
                match op {
                    Op::Put { key, value } => {
                        assert_eq!(txn.put(key, value).unwrap(), oracle.put(key, value))
                    }
                    Op::Delete { key } => assert_eq!(txn.delete(key).unwrap(), oracle.delete(key)),
                    Op::Get { key } => assert_eq!(txn.get(key), oracle.get(key)),
                    Op::Range { lo, hi } => {
                        assert_eq!(entries(txn.view(), lo, hi), oracle.range(lo, hi))
                    }
                }
            }
            // Until commit, the outside world sees the old tree.
            assert_eq!(
                entries(txn.committed().view(), 0, MAX_KEY),
                saved.range(0, MAX_KEY)
            );
            if batch % 5 == 4 {
                txn.abort();
                oracle = saved;
                assert_eq!(db.current, before);
            } else {
                txn.commit().unwrap();
            }
            assert_eq!(entries(db.view(), 0, MAX_KEY), oracle.range(0, MAX_KEY));
            if batch % 3 == 0 {
                db.validate().unwrap();
            }
            batch += 1;
        }
        db.validate().unwrap();
        assert!(db.pending.is_empty());
    }
}

// --------------------------------------------------- running out of pages

#[test]
fn a_transaction_that_runs_out_of_pages_leaves_no_trace() {
    let mut db = build_canonical();
    let snap = db.snapshot();

    // Transactions of different sizes, each retried with a budget one page
    // larger until it commits: the failure hits every allocation point.
    let mut failures = 0;
    for size in 1..25u64 {
        for budget in 0.. {
            let meta_before = db.store.meta_slots;
            let free_before = db.store.free.clone();
            let count_before = db.len();
            db.page_budget = Some(budget);

            let mut txn = db.begin();
            let result: Result<(), TxnError> = (|| {
                for k in 0..size {
                    txn.put(1000 * size + k, k)?;
                }
                txn.delete(CANONICAL[size as usize % CANONICAL.len()])?;
                Ok(())
            })();
            match result {
                Ok(()) => {
                    txn.commit().unwrap();
                    db.validate().unwrap();
                    break;
                }
                Err(err) => {
                    assert_eq!(err, TxnError::OutOfPages);
                    failures += 1;
                    // put/delete failed: the transaction is poisoned, commit
                    // refuses and the transaction is dropped (= aborted).
                    assert!(txn.failed());
                    assert_eq!(txn.commit(), Err(TxnError::TxnFailed));
                    // Nothing happened, as far as anyone can tell.
                    assert_eq!(db.store.meta_slots, meta_before);
                    assert_eq!(db.store.free, free_before);
                    assert_eq!(db.len(), count_before);
                    db.validate().unwrap();
                    assert_eq!(keys(snap.view(&db)), SORTED);
                }
            }
        }
    }
    assert!(failures > 40);
    db.page_budget = None;
    db.release(snap);
    db.validate().unwrap();
}

// ------------------------------------------- validate catches corruption

#[test]
fn validate_names_the_broken_invariant() {
    // Every case starts from: canonical tree, snapshot at txn 12, then
    // `put 13` as txn 13. Pages #0 #4 #9 are pending (old path), #2 #5 #10
    // are the new path, #1 #3 #6 #7 #8 are shared by both roots.
    type Corrupt = fn(&mut Db);
    let cases: [(Violation, Corrupt); 12] = [
        (Violation::LivePageModified, |db| {
            // "Someone" rewrote a shared page in place as transaction 13:
            // legal for the current root, a lie to the snapshot of 12.
            db.store.slots[6].written_by = 13;
        }),
        (Violation::ReachablePageIsFree, |db| {
            db.store.release(PageId::from_index(7)); // a live leaf becomes writable
        }),
        (Violation::ReachablePageIsFree, |db| {
            // Reclaim too early: pretend the snapshot is not there.
            let saved = std::mem::take(&mut db.snapshots);
            db.reclaim();
            db.snapshots = saved;
        }),
        (Violation::SnapshotPageUnprotected, |db| {
            for p in &mut db.pending {
                p.freed_by = 12; // "freed by 12" would be releasable
            }
        }),
        (Violation::FreeListCorrupt, |db| {
            db.store.free.push(PageId::from_index(1)); // listed but live
        }),
        (Violation::PendingCorrupt, |db| {
            db.pending[0].page = PageId::from_index(10); // a page of the current tree
        }),
        (Violation::PageLeak, |db| {
            db.pending.pop(); // forgotten: neither reachable, pending nor free
            db.snapshots.clear();
        }),
        (Violation::PageReachedTwice, |db| {
            // The sibling-link disease: one leaf under two parents.
            let root = db.current.root.index();
            let left = db.store.slots[root].node.internal().children[0].index();
            let children = &mut db.store.slots[left].node.internal_mut().children;
            children[1] = children[0];
        }),
        (Violation::KeyOutOfBounds, |db| {
            db.store.slots[10].node.keys[2] = 99; // leaf (10 12 13) under [6 10 | 15)
        }),
        (Violation::WrongCount, |db| {
            db.snapshots[0].snap.count += 1;
        }),
        (Violation::BadMeta, |db| {
            db.store.meta_slots[1][3] ^= 0x40; // newest slot torn: current is no longer the winner
        }),
        (Violation::DanglingChild, |db| {
            let root = db.current.root.index();
            db.store.slots[root].node.internal_mut().children[1] = PageId::from_index(500);
        }),
    ];
    for (expected, corrupt) in cases {
        let mut db = build_canonical();
        let _snap = db.snapshot();
        db.put(13, 1300).unwrap();
        db.validate().unwrap();
        corrupt(&mut db);
        assert_eq!(db.validate(), Err(expected));
    }
}
