//! Tests of the whole model: fixed scenarios for every mechanism, the two
//! page-deletion tests the chapter is built around, the page budget (Rust's
//! stand-in for allocation failure), a seeded model test against the oracle,
//! and proof that `validate` catches corruption. (The base_* files and
//! store.rs carry their own unit tests.)

use crate::base_arena::{NodeId, OutOfNodes};
use crate::base_node::{self as node, PageState};
use crate::db::{Cursor, DanglingLink, Db, VacuumOptions};
use crate::dump;
use crate::ops::{Config, Entry, Op, OpStream, Oracle, Weights};
use crate::validate::Violation;

const EVERYTHING: u64 = u64::MAX;
const KEEP_PAGES: VacuumOptions = VacuumOptions {
    delete_pages: false,
};

fn vacuum(db: &mut Db) -> crate::db::VacuumReport {
    db.vacuum(VacuumOptions::default())
}

fn dump_string(db: &Db) -> String {
    let mut out = Vec::new();
    dump::dump(db, &mut out).unwrap();
    String::from_utf8(out).unwrap()
}

fn next_key(cursor: &mut Cursor, db: &mut Db) -> Option<u64> {
    cursor.next(db).unwrap().map(|row| row.key)
}

/// Keys of a full scan under a snapshot opened (and closed) for it.
fn scan_keys(db: &mut Db) -> Vec<u64> {
    let s = db.store.open_snapshot().unwrap();
    let mut cursor = Cursor::seek(db, s, 0, EVERYTHING);
    let mut keys = Vec::new();
    while let Some(k) = next_key(&mut cursor, db) {
        keys.push(k);
    }
    db.store.close_snapshot(s);
    keys
}

fn drain(cursor: &mut Cursor, db: &mut Db) {
    while cursor.next(db).unwrap().is_some() {}
}

/// Rows 10..120, rows 30..80 deleted, entries vacuumed, empty pages kept:
///   #0(10 20) -> #1() -> #3() -> #4() -> #5(90 100) -> #8(110 120)
/// with #1 and #3 under internal page #2 and #4 the first child of #6.
fn build_with_empty_leaves() -> Db {
    let mut db = Db::new(4);
    for key in (10..=120).step_by(10) {
        db.put(key, key * 10).unwrap();
    }
    for key in (30..=80).step_by(10) {
        db.delete(key);
    }
    assert_eq!(db.vacuum(KEEP_PAGES).entries_removed, 6);
    db.validate().unwrap();
    db
}

fn id(i: usize) -> NodeId {
    NodeId::from_index(i)
}

#[test]
fn a_snapshot_keeps_seeing_the_versions_that_existed_when_it_was_taken() {
    let mut db = Db::new(4);
    assert_eq!(db.put(1, 100), Ok(None));
    assert_eq!(db.put(2, 200), Ok(None));
    let old = db.store.open_snapshot().unwrap();
    assert_eq!(db.put(1, 101), Ok(Some(100))); // update
    assert_eq!(db.delete(2), Some(200));
    assert_eq!(db.put(3, 300), Ok(None)); // insert
    assert_eq!(db.delete(2), None); // already deleted
    let new = db.store.open_snapshot().unwrap();

    assert_eq!(db.get(old, 1), Ok(Some(100)));
    assert_eq!(db.get(old, 2), Ok(Some(200)));
    assert_eq!(db.get(old, 3), Ok(None));
    assert_eq!(db.get(new, 1), Ok(Some(101)));
    assert_eq!(db.get(new, 2), Ok(None));
    assert_eq!(db.get(new, 3), Ok(Some(300)));
    // An update added an entry; a delete removed none: 4 entries for 2 rows.
    assert_eq!(db.index.count, 4);
    db.validate().unwrap();
    db.store.close_snapshot(old);
    db.store.close_snapshot(new);
}

#[test]
fn hints_are_set_only_for_versions_dead_to_everyone_and_save_heap_visits() {
    let mut db = Db::new(8);
    for k in 1..6 {
        db.put(k, k).unwrap();
    }
    let old = db.store.open_snapshot().unwrap();
    db.delete(2);
    db.delete(4);
    let new = db.store.open_snapshot().unwrap();

    // `old` still sees rows 2 and 4, so they are invisible to `new` but not dead.
    drain(&mut Cursor::seek(&db, new, 0, EVERYTHING), &mut db);
    assert_eq!(db.reads.hints_set, 0);
    assert_eq!(db.reads.heap_fetches, 5);

    db.store.close_snapshot(old);
    drain(&mut Cursor::seek(&db, new, 0, EVERYTHING), &mut db);
    assert_eq!(db.reads.hints_set, 2);
    assert_eq!(db.reads.heap_fetches, 10);
    db.validate().unwrap(); // includes "no hint lies"

    drain(&mut Cursor::seek(&db, new, 0, EVERYTHING), &mut db);
    assert_eq!(db.reads.hint_skips, 2);
    assert_eq!(db.reads.heap_fetches, 13); // 3 this time, not 5
    db.store.close_snapshot(new);
}

#[test]
fn a_full_leaf_drops_hinted_entries_instead_of_splitting_simple_deletion() {
    let mut db = Db::new(4);
    db.index.bottom_up = false; // isolate the hint path
    for k in [10, 20, 30] {
        db.put(k, k).unwrap();
    }
    db.delete(20);
    // Without a hint the insert cannot know that 20 is garbage: it splits.
    db.put(40, 40).unwrap();
    assert_eq!(db.index.stats.leaf_splits, 1);
    assert_eq!(scan_keys(&mut db), [10, 30, 40]); // this scan hints the entry of 20
    assert_eq!(db.reads.hints_set, 1);
    // 20 sits in the left leaf (10, 20): fill it and insert once more.
    db.put(12, 12).unwrap();
    db.put(14, 14).unwrap();
    assert_eq!(db.index.stats.simple_deleted, 1);
    assert_eq!(db.index.stats.splits_avoided, 1);
    assert_eq!(db.index.stats.leaf_splits, 1);
    assert_eq!(scan_keys(&mut db), [10, 12, 14, 30, 40]);
    db.validate().unwrap();
}

#[test]
fn bottom_up_deletion_absorbs_version_churn_unless_a_snapshot_needs_the_versions() {
    let mut db = Db::new(4);
    for i in 0..50 {
        db.put(7, i).unwrap(); // 50 versions of one row
    }
    assert_eq!(db.index.stats.leaf_splits, 0);
    assert_eq!(db.index.nodes.live_count(), 1);
    assert!(db.index.stats.bottom_up_deleted > 0);
    // Version slots are reused too: a full page (3) plus the version being
    // added is the most the store ever held.
    assert_eq!(db.store.versions.slot_count(), 4);

    let pin = db.store.open_snapshot().unwrap();
    for i in 50..60 {
        db.put(7, i).unwrap();
    }
    assert!(db.index.stats.leaf_splits > 0); // nothing was removable
    assert_eq!(db.get(pin, 7), Ok(Some(49)));
    db.store.close_snapshot(pin);
    db.validate().unwrap();
}

#[test]
fn vacuum_removes_exactly_what_the_oldest_snapshot_cannot_see() {
    let mut db = Db::new(4);
    for k in 1..10 {
        db.put(k, k).unwrap();
    }
    let pin = db.store.open_snapshot().unwrap();
    for k in 1..10 {
        db.delete(k);
    }
    assert_eq!(vacuum(&mut db).entries_removed, 0);
    assert_eq!(db.index.count, 9);
    let mut cursor = Cursor::seek(&db, pin, 0, EVERYTHING);
    for k in 1..10 {
        assert_eq!(next_key(&mut cursor, &mut db), Some(k));
    }

    db.store.close_snapshot(pin);
    let report = vacuum(&mut db);
    assert_eq!(report.entries_removed, 9);
    assert_eq!(db.index.count, 0);
    assert_eq!(db.store.versions.live_count(), 0);
    assert_eq!(report.pages_unlinked, report.pages_recycled);
    assert_eq!(report.pages_waiting, 0);
    assert_eq!(scan_keys(&mut db), []);
    db.validate().unwrap();
}

#[test]
fn page_deletion_phase_1_rewires_the_parent_phase_2_the_sibling_chain() {
    let mut db = build_with_empty_leaves();
    assert_eq!(
        dump_string(&db),
        "now=18 horizon=18 | height 3, 6 entries, 9 pages\n\
         \x20 level 0: #7[70.6]\n\
         \x20 level 1: #2[30.2 50.4] #6[90.8 110.10]\n\
         \x20 leaves : #0(10:1- 20:2-) -> #1() -> #3() -> #4() -> #5(90:9- 100:10-) -> #8(110:11- 120:12-)\n"
    );

    // Not allowed: non-empty, rightmost child of its parent, internal, root, nil.
    for bad in [id(0), id(3), id(8), id(2), id(7), NodeId::NIL] {
        assert!(!db.index.mark_half_dead(bad));
    }

    assert!(db.index.mark_half_dead(id(1)));
    assert!(!db.index.mark_half_dead(id(1))); // not twice
    // Slot 1 of #2 now points at #3 and separator 50 is gone: #3 inherited
    // the key range of #1 and no key in any leaf was touched.
    assert_eq!(db.index.nodes.get(id(2)).child_slice(), [id(0), id(3)]);
    assert_eq!(db.index.find_leaf(node::pack_low(35)), id(3));
    assert_eq!(db.index.nodes.get(id(0)).leaf().next, id(1)); // still chained
    db.validate().unwrap();

    let left = db.index.left_sibling(id(1));
    db.index.unlink_half_dead(&mut db.store, left, id(1));
    assert_eq!(
        dump_string(&db),
        "now=19 horizon=19 | height 3, 6 entries, 9 pages\n\
         \x20 level 0: #7[70.6]\n\
         \x20 level 1: #2[30.2] #6[90.8 110.10]\n\
         \x20 leaves : #0(10:1- 20:2-) -> #3() -> #4() -> #5(90:9- 100:10-) -> #8(110:11- 120:12-)\n\
         \x20 deleted: #1@19->#3\n"
    );
    db.validate().unwrap();
    assert_eq!(db.index.recycle(db.store.horizon()), 1);
    assert_eq!(db.index.nodes.live_count(), 8);
    db.validate().unwrap();
}

#[test]
fn a_scan_about_to_step_onto_a_page_that_is_then_deleted_moves_right_safely() {
    let mut db = build_with_empty_leaves();

    // The scan reads leaf #0 and remembers its right link, #1.
    let s = db.store.open_snapshot().unwrap();
    let mut cursor = Cursor::seek(&db, s, 0, EVERYTHING);
    assert_eq!(next_key(&mut cursor, &mut db), Some(10));
    assert_eq!(next_key(&mut cursor, &mut db), Some(20));
    assert_eq!(cursor.next_leaf, id(1));

    // While it is paused, VACUUM deletes #1 (and #4) in both phases.
    let report = vacuum(&mut db);
    assert_eq!(report.pages_unlinked, 2);
    // ... but may not recycle them: snapshot s is older than their stamps.
    assert_eq!(report.pages_recycled, 0);
    assert_eq!(report.pages_waiting, 2);
    assert_eq!(db.index.recycle(db.store.horizon()), 0);
    let PageState::Deleted(stamp) = db.index.nodes.get(id(1)).leaf().state else {
        panic!("#1 should be deleted");
    };
    assert!(s < stamp);
    db.validate().unwrap();

    // Writers keep going; their splits must grow the array, not reuse #1.
    let slots = db.index.nodes.slot_count();
    for k in [11, 12, 13, 14] {
        db.put(k, k).unwrap();
    }
    assert!(db.index.nodes.slot_count() > slots);
    assert_eq!(db.index.stats.pages_reused, 0);

    // The scan follows its stale link, finds a deleted page whose own right
    // link is intact, and moves right. Nothing is missed or repeated.
    for k in [90, 100, 110, 120] {
        assert_eq!(next_key(&mut cursor, &mut db), Some(k));
    }
    assert_eq!(next_key(&mut cursor, &mut db), None);
    assert!(db.reads.moved_right >= 1);

    // Once the snapshot is gone the pages are recycled, and the next split
    // reuses one of them instead of growing the page array.
    db.store.close_snapshot(s);
    assert_eq!(db.index.recycle(db.store.horizon()), 2);
    assert_eq!(db.index.nodes.free_count(), Some(2));
    let slots_after = db.index.nodes.slot_count();
    for k in [91, 92] {
        db.put(k, k).unwrap();
    }
    assert_eq!(db.index.stats.pages_reused, 1);
    assert_eq!(db.index.nodes.slot_count(), slots_after);
    assert_eq!(
        scan_keys(&mut db),
        [10, 11, 12, 13, 14, 20, 90, 91, 92, 100, 110, 120]
    );
    db.validate().unwrap();
}

#[test]
fn recycling_a_deleted_page_too_early_breaks_the_same_scan() {
    let mut db = build_with_empty_leaves();
    let s = db.store.open_snapshot().unwrap();
    let mut cursor = Cursor::seek(&db, s, 0, EVERYTHING);
    next_key(&mut cursor, &mut db);
    next_key(&mut cursor, &mut db); // 10, 20; paused before #1

    assert!(db.index.mark_half_dead(id(1)));
    db.index.unlink_half_dead(&mut db.store, id(0), id(1));
    assert_eq!(db.index.recycle(db.store.horizon()), 0); // the rule says no
    assert_eq!(db.index.recycle_ignoring_snapshots(), 1); // the bug

    // Failure 1: the page is on the free list; the link points at nothing.
    let mut early = cursor.clone();
    assert_eq!(early.next(&mut db), Err(DanglingLink));

    // Failure 2 (worse): a split at the far right end reuses page #1. The
    // scan lands in the middle of somebody else's keys, returns the one row
    // its snapshot can see there, and never visits #5 and #8.
    for k in [111, 112] {
        db.put(k, k).unwrap();
    }
    assert_eq!(db.index.stats.pages_reused, 1);
    assert_eq!(next_key(&mut cursor, &mut db), Some(120));
    assert_eq!(next_key(&mut cursor, &mut db), None); // 90, 100, 110 lost
    db.validate().unwrap(); // the TREE is fine; only the reader was betrayed
    db.store.close_snapshot(s);
}

#[test]
fn a_deletion_interrupted_after_phase_1_is_harmless_and_finished_by_the_next_vacuum() {
    let mut db = build_with_empty_leaves();
    assert!(db.index.mark_half_dead(id(1)));
    db.validate().unwrap();
    // Scans skip the half-dead page; inserts into its old key range go to
    // the right sibling, because the parent no longer points at it.
    assert_eq!(scan_keys(&mut db), [10, 20, 90, 100, 110, 120]);
    db.put(35, 350).unwrap();
    assert_eq!(db.index.nodes.get(id(1)).len, 0);
    assert_eq!(db.index.nodes.get(id(3)).len, 1);
    assert_eq!(scan_keys(&mut db), [10, 20, 35, 90, 100, 110, 120]);

    let report = vacuum(&mut db);
    assert_eq!(report.pages_unlinked, 2); // #1 finished, #4 start to end
    assert_eq!(report.pages_recycled, 2);
    db.validate().unwrap();
}

#[test]
fn the_leftmost_leaf_can_be_deleted_the_chain_gets_a_new_head() {
    let mut db = Db::new(4);
    for k in 1..9 {
        db.put(k, k).unwrap();
    }
    db.delete(1);
    db.delete(2);
    let head = db.index.first_leaf;
    let report = vacuum(&mut db);
    assert_eq!(report.pages_unlinked, 1);
    assert_ne!(db.index.first_leaf, head);
    assert!(!db.index.nodes.is_live(head));
    assert_eq!(scan_keys(&mut db), [3, 4, 5, 6, 7, 8]);
    assert_eq!(db.delete(1), None);
    db.put(1, 11).unwrap(); // lands in the new head
    assert_eq!(scan_keys(&mut db), [1, 3, 4, 5, 6, 7, 8]);
    db.validate().unwrap();
}

#[test]
fn put_over_budget_changes_nothing() {
    // Zig fails the n-th allocation; here the n-th page or version is refused.
    for (max_pages, max_versions) in [(1, 100), (2, 100), (3, 100), (5, 100), (100, 2), (100, 7)] {
        let mut db = Db::with_budgets(4, max_pages, max_versions);
        let mut failed = false;
        for i in 0..40 {
            let key = (i * 7) % 20;
            let (entries, now) = (db.index.count, db.store.now);
            if db.put(key, i) == Err(OutOfNodes) {
                // Not even the transaction counter moved.
                assert_eq!((db.index.count, db.store.now), (entries, now));
                failed = true;
                break;
            }
        }
        assert!(failed, "budget ({max_pages}, {max_versions}) was never hit");
        db.validate().unwrap();
    }
}

#[test]
fn model_random_operations_with_a_long_lived_snapshot_match_the_oracle() {
    for order in [3usize, 4, 5, 16] {
        let mut db = Db::new(order);
        db.index.bottom_up = order != 5; // one run without it
        let mut oracle = Oracle::new();
        let mut frozen: Vec<Entry> = Vec::new();
        let mut long = None;
        let config = Config {
            seed: 0xC0FFEE + order as u64,
            count: 6000,
            key_space: 150,
            weights: Weights::default(),
        };
        for (step, op) in OpStream::new(config).enumerate() {
            match op {
                Op::Put { key, value } => {
                    assert_eq!(db.put(key, value), Ok(oracle.put(key, value)))
                }
                Op::Delete { key } => assert_eq!(db.delete(key), oracle.delete(key)),
                Op::Get { key } => {
                    let s = db.store.open_snapshot().unwrap();
                    assert_eq!(db.get(s, key), Ok(oracle.get(key)));
                    db.store.close_snapshot(s);
                }
                Op::Range { lo, hi } => {
                    let s = db.store.open_snapshot().unwrap();
                    expect_scan(&mut db, s, lo, hi, oracle.range(lo, hi));
                    db.store.close_snapshot(s);
                }
            }
            if step % 300 == 50 {
                long = Some(db.store.open_snapshot().unwrap());
                frozen.clear();
                frozen.extend_from_slice(oracle.range(0, u64::MAX));
            }
            if step % 300 == 250 {
                let s = long.take().unwrap();
                expect_scan(&mut db, s, 0, 150, &frozen);
                db.store.close_snapshot(s);
            }
            if step % 97 == 96 {
                vacuum(&mut db);
            }
            if step % 50 == 49 {
                db.validate().unwrap();
            }
        }
        if let Some(s) = long {
            db.store.close_snapshot(s);
        }
        assert!(db.index.stats.pages_recycled > 0 || order == 16);
        assert!(db.index.stats.vacuum_deleted > 0);

        // Delete every row and vacuum: every entry and every version is
        // reclaimed, and only the pages the rules protect remain.
        for k in 0..150 {
            db.delete(k);
        }
        let report = vacuum(&mut db);
        assert_eq!(db.index.count, 0);
        assert_eq!(db.store.versions.live_count(), 0);
        assert_eq!(report.pages_waiting, 0);
        db.validate().unwrap();
        // Reclaimed slots are reused: loading the rows again needs no more
        // version slots and no more pages than the arenas already hold.
        let version_slots = db.store.versions.slot_count();
        let page_slots = db.index.nodes.slot_count();
        for e in oracle.range(0, u64::MAX) {
            db.put(e.key, e.value).unwrap();
        }
        assert_eq!(db.store.versions.slot_count(), version_slots);
        assert_eq!(db.index.nodes.slot_count(), page_slots);
        db.validate().unwrap();
    }
}

fn expect_scan(db: &mut Db, snapshot: u64, lo: u64, hi: u64, expected: &[Entry]) {
    let mut cursor = Cursor::seek(db, snapshot, lo, hi);
    for e in expected {
        let row = cursor.next(db).unwrap().unwrap();
        assert_eq!((row.key, row.value), (e.key, e.value));
    }
    assert_eq!(cursor.next(db), Ok(None));
}

#[test]
fn validate_names_the_broken_invariant() {
    let mut db = build_with_empty_leaves();

    db.index.nodes.get_mut(id(0)).leaf_mut().dead[0] = true; // row 10 is alive
    assert_eq!(db.validate(), Err(Violation::LyingHint));
    db.index.nodes.get_mut(id(0)).leaf_mut().dead[0] = false;

    let key0 = db.index.nodes.get(id(0)).keys[0];
    db.index.nodes.get_mut(id(0)).keys[0] = node::pack(10, id(1)); // tid of row 20
    assert_eq!(db.validate(), Err(Violation::DanglingTid));
    db.index.nodes.get_mut(id(0)).keys[0] = key0;

    db.index.nodes.get_mut(id(0)).leaf_mut().next = id(3); // chain skips #1, the tree does not
    assert_eq!(db.validate(), Err(Violation::BrokenLeafChain));
    db.index.nodes.get_mut(id(0)).leaf_mut().next = id(1);

    db.index.nodes.get_mut(id(1)).leaf_mut().state = PageState::HalfDead; // still has a downlink
    assert_eq!(db.validate(), Err(Violation::DeadPageInTree));
    db.index.nodes.get_mut(id(1)).leaf_mut().state = PageState::Live;

    db.store.versions.get_mut(node::tid_of(key0)).xmin = 99; // from the future
    assert_eq!(db.validate(), Err(Violation::BadTimestamp));
    db.store.versions.get_mut(node::tid_of(key0)).xmin = 1;
    db.validate().unwrap();
}
