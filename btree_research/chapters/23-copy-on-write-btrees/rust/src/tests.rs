//! Tests of the whole database: path copying, snapshots, deferred reuse,
//! abort, the metapage, restarts after crashes and slot damage, seeded model
//! tests with snapshots, the page budget (Rust's stand-in for allocation
//! failure), and proof that `validate` catches corruption.

use crate::base_node::PageId;
use crate::db::{Db, ReopenError, Snapshot};
use crate::dump;
use crate::meta::{Meta, SLOT_SIZE};
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

/// The whole tree. NOT `range(0, MAX_KEY)`: `hi` is exclusive, so that
/// would silently skip the key `u64::MAX`.
fn keys(view: View<'_>) -> Vec<u64> {
    view.seek(0).map(|e| e.key).collect()
}

fn all(view: View<'_>) -> Vec<Entry> {
    view.seek(0)
        .map(|e| Entry {
            key: e.key,
            value: e.value,
        })
        .collect()
}

/// Everything the oracle holds (its `range` is half-open too).
fn oracle_all(oracle: &Oracle) -> Vec<Entry> {
    let mut v = oracle.range(0, MAX_KEY).to_vec();
    if let Some(value) = oracle.get(MAX_KEY) {
        v.push(Entry {
            key: MAX_KEY,
            value,
        });
    }
    v
}

/// With no reader left, the only pages still waiting are the ones the
/// newest commit replaced: the previous root (the fallback) reaches them.
fn assert_only_fallback_pending(db: &Db) {
    assert!(db.pending.iter().all(|p| p.freed_by == db.current.txn_id));
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
txn 12: root #11, height 3, 12 keys
  level 0: #11[15]
  level 1: #7[6 10] #10[20]
  leaves : #5(1 3 5) #8(6 7) #0(10 12) | #9(15 17) #3(20 25 30)
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
    // Released: the 2 pages txn 12 replaced. The 3 this commit replaced stay.
    assert_eq!(info.released, 2);
    assert_eq!(db.pending.len(), 3);

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
    assert_only_fallback_pending(&db);
}

#[test]
fn freed_pages_are_reused_only_after_the_snapshots_that_need_them_are_gone() {
    let mut db = build_canonical();

    // Without a snapshot the pages a commit replaces are free one commit
    // later, and the store stops growing: it holds the tree plus two paths
    // (the one being written and the one the fallback root still needs).
    // (Two warm-up commits, until the free list holds a path of 3.)
    for i in 0..2 {
        db.put(10, i).unwrap();
    }
    let pages_before = db.store.page_count();
    for i in 0..20 {
        db.put(10, i).unwrap();
    }
    assert_eq!(db.store.page_count(), pages_before);
    assert_eq!(db.pending.len(), 3); // the newest commit's
    assert_only_fallback_pending(&db);

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
    // All but the newest commit's 3: the fallback root still reaches those.
    assert_eq!(db.release(second), 57);
    assert_only_fallback_pending(&db);
    assert_eq!(db.pending.len(), 3);
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
    // Now the oldest protected root is the fallback, txn 13: the pages
    // freed by 13 go, the pages freed by 14 wait for the next commit.
    assert_eq!(db.release(old), 3);
    assert_only_fallback_pending(&db);
    db.validate().unwrap();
    db.put(15, 1).unwrap(); // txn 15 overwrites the slot of txn 13
    assert_eq!(db.pending.len(), 3);
    assert_only_fallback_pending(&db);
}

#[test]
fn pages_replaced_by_a_commit_become_reusable_one_commit_later_not_at_once() {
    let mut db = build_canonical();
    // The pages of the tree of txn 12.
    let before: Vec<PageId> = reachable(&db, db.view())
        .iter()
        .enumerate()
        .filter(|&(_, &m)| m)
        .map(|(i, _)| PageId::from_index(i))
        .collect();
    assert_eq!(db.previous.unwrap().txn_id, 11);

    // Txn 13 replaces a path of 3. No snapshot is held, and still none of
    // the 3 is free: meta slot 0 names txn 12, and a restart may choose it.
    let mut txn = db.begin();
    txn.put(13, 1300).unwrap();
    let info = txn.commit().unwrap();
    assert_eq!(info.freed, 3);
    assert_eq!(db.previous.unwrap().txn_id, 12);
    assert!(before.iter().all(|&id| db.store.is_live(id)));
    assert_eq!(db.pending.len(), 3);

    // Txn 14 could use them (it does not get them), and releases them once
    // its own meta slot has replaced the one of txn 12.
    db.put(14, 1400).unwrap();
    assert_eq!(db.previous.unwrap().txn_id, 13);
    assert_eq!(before.iter().filter(|&&id| !db.store.is_live(id)).count(), 3);
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
    // Every page is free except the last leaf: the fallback root (the tree
    // with one key) still reaches it until the next commit.
    assert_eq!(db.pending.len(), 1);
    assert_eq!(db.store.free.len(), db.store.page_count() - 1);
    assert_eq!(db.get(10), None);
    assert_eq!(keys(db.view()), []);
    db.put(7, 70).unwrap();
    assert_eq!(db.pending.len(), 0);
    assert_eq!(db.store.free.len(), db.store.page_count() - 1);
    assert_eq!(db.get(7), Some(70));
    db.validate().unwrap();
}

#[test]
fn a_full_scan_reaches_the_largest_key_range_lo_hi_excludes_hi() {
    let mut db = Db::new(4);
    db.put(MAX_KEY, 1).unwrap();
    db.put(5, 2).unwrap();
    db.put(0, 3).unwrap();
    assert_eq!(keys(db.view()), [0, 5, MAX_KEY]);
    assert_eq!(db.get(MAX_KEY), Some(1));
    // Half-open: stops before MAX_KEY.
    assert_eq!(db.range(0, MAX_KEY).map(|e| e.key).collect::<Vec<_>>(), [0, 5]);
    assert_eq!(db.delete(MAX_KEY), Ok(Some(1)));
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
            // The newest slot is unreadable: after a restart the previous
            // commit must be complete, although this commit already reused
            // pages (only pages the previous root could not reach).
            db.store.meta_slots[(id % 2) as usize][(i % 32) as usize] ^= 0x01;
            db.reopen().unwrap();
            assert_eq!(db.current.txn_id, id - 1);
            db.validate().unwrap();
            assert_eq!(all(db.view()), oracle_all(&previous));
            assert_eq!(db.previous, None); // no second slot to fall back to
            oracle = previous;
        } else if i % 4 == 1 {
            let fallback = db.previous;
            db.reopen().unwrap(); // a clean restart changes nothing
            assert_eq!(db.current.txn_id, id);
            assert_eq!(db.previous, fallback); // and keeps the fallback protected
            db.validate().unwrap();
            assert_eq!(all(db.view()), oracle_all(&oracle));
        }
    }
    db.store.meta_slots[0][0] ^= 1;
    db.store.meta_slots[1][0] ^= 1;
    assert_eq!(db.reopen(), Err(ReopenError::NoValidMeta));
}

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

// ------------------------------------------- restarts after crash and damage

/// What survives a power failure: the pages and the two meta slots. The
/// in-memory half of the copy is that of a fresh database (wrong on
/// purpose): `reopen` has to rebuild all of it from the "disk".
fn disk_image(db: &Db) -> Db {
    let mut copy = Db::new(db.max_keys() + 1); // M = max keys + 1
    copy.store.slots = db.store.slots.clone();
    copy.store.meta_slots = db.store.meta_slots;
    copy
}

/// A complete copy, so that one commit can be crashed many times.
fn clone_db(db: &Db) -> Db {
    let mut copy = disk_image(db);
    copy.store.free = db.store.free.clone();
    copy.pending = db.pending.clone();
    copy.current = db.current;
    copy.previous = db.previous;
    copy
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Damage {
    None,
    BitFlip,
    Zeroed,
    Ones,
}

fn damage(slot: &mut [u8; SLOT_SIZE], how: Damage, salt: usize) {
    match how {
        Damage::None => {}
        Damage::BitFlip => slot[(salt / 8) % 32] ^= 1 << (salt % 8),
        Damage::Zeroed => slot.fill(0),
        Damage::Ones => slot.fill(0xFF),
    }
}

/// Small private SplitMix64 for the randomized restart tests.
struct Rng(u64);

impl Rng {
    fn below(&mut self, n: u64) -> u64 {
        self.0 = self.0.wrapping_add(0x9E37_79B9_7F4A_7C15);
        let mut z = self.0;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        (z ^ (z >> 31)) % n
    }
}

fn newest_readable(db: &Db) -> Option<u64> {
    let ids = db.store.meta_slots.iter().filter_map(|s| Meta::decode(s).map(|m| m.txn_id));
    ids.max()
}

/// THE property of the two-slot metapage. `history[t]` is the content
/// transaction t committed. Whatever is left on the disk: if a meta slot is
/// readable, a restart succeeds and finds exactly the content of the newest
/// readable commit, in a store that passes `validate` and can go on working.
fn assert_clean_restart(disk: &mut Db, history: &[Vec<Entry>]) -> Option<u64> {
    let Some(want) = newest_readable(disk) else {
        assert_eq!(disk.reopen(), Err(ReopenError::NoValidMeta));
        return None;
    };
    disk.reopen().unwrap();
    assert_eq!(disk.current.txn_id, want);
    disk.validate().unwrap();
    assert_eq!(all(disk.view()), history[want as usize]);
    // Life goes on: commit twice (the second reuses pages the first freed),
    // and restart once more.
    disk.put(1_000_000, 1).unwrap();
    disk.validate().unwrap();
    disk.put(1_000_001, 2).unwrap();
    disk.validate().unwrap();
    disk.reopen().unwrap();
    disk.validate().unwrap();
    assert_eq!(disk.len(), history[want as usize].len() as u64 + 2);
    Some(want)
}

#[test]
fn newest_slot_unreadable_while_the_next_commit_is_in_flight_the_older_slot_names_a_whole_tree() {
    let mut db = build_canonical();
    // Txn 13 writes its 3 pages and loses power before its meta write.
    db.crash_after = Some(3);
    assert_eq!(db.put(13, 1300), Err(TxnError::Crashed));
    // On top of that the slot of txn 12 has rotted. The only readable slot
    // is that of txn 11, which was one write away from being overwritten.
    db.store.meta_slots[0][3] ^= 1;
    db.reopen().unwrap();
    assert_eq!(db.current.txn_id, 11);
    db.validate().unwrap();
    assert_eq!(keys(db.view()), [1, 3, 5, 6, 7, 10, 12, 17, 20, 25, 30]); // no 15, no 13
}

#[test]
fn restart_after_a_crash_at_any_write_with_either_slot_damaged_finds_a_complete_committed_tree() {
    let mut fell_back_two = 0; // restarts that landed on T-2 while T was in flight
    let mut cases = 0;
    for order in [3usize, 4] {
        let mut db = Db::new(order);
        let mut oracle = Oracle::new();
        let mut history: Vec<Vec<Entry>> = vec![Vec::new()]; // txn 0: empty

        // Small key space: splits, borrows, merges, root growth and shrink.
        for op in OpStream::new(config(40 + order as u64, 150, 14)) {
            let (key, value, is_put) = match op {
                Op::Put { key, value } => (key, value, true),
                Op::Delete { key } => (key, 0, false),
                _ => continue,
            };
            if !is_put && oracle.get(key).is_none() {
                continue; // commits nothing
            }
            if is_put {
                oracle.put(key, value);
            } else {
                oracle.delete(key);
            }
            let t = db.current.txn_id + 1;
            history.push(oracle_all(&oracle)); // history[t]

            // Crash the commit of transaction t after w device writes, for
            // every w, until it gets through.
            for w in 0.. {
                let mut trial = clone_db(&db);
                trial.crash_after = Some(w);
                let result = if is_put { trial.put(key, value) } else { trial.delete(key) };
                let done = result.is_ok();
                if !done {
                    assert_eq!(result, Err(TxnError::Crashed));
                }

                // The disk as the crash left it, then with one slot damaged.
                for slot in [0, 1] {
                    for how in [Damage::None, Damage::BitFlip, Damage::Zeroed, Damage::Ones] {
                        if how == Damage::None && slot == 1 {
                            continue;
                        }
                        let mut disk = disk_image(&trial);
                        damage(&mut disk.store.meta_slots[slot], how, w * 31 + t as usize);
                        let landed = assert_clean_restart(&mut disk, &history);
                        cases += 1;
                        if how == Damage::None {
                            // No damage: a crash loses the commit in flight
                            // and nothing else. (A crash before the LAST meta
                            // bytes can leave a complete slot, when those
                            // bytes happen to equal the ones they replace.)
                            let landed = landed.unwrap();
                            if done {
                                assert_eq!(landed, t);
                            }
                            if w == 0 {
                                assert_eq!(landed, t - 1);
                            }
                            assert!(landed == t || landed == t - 1);
                        } else if landed.is_some_and(|l| l + 2 == t) {
                            fell_back_two += 1;
                        }
                    }
                }
                if done {
                    break;
                }
            }
            // The real line of history moves on without a crash.
            if is_put {
                db.put(key, value).unwrap();
            } else {
                db.delete(key).unwrap();
            }
            assert_eq!(db.current.txn_id, t);
        }
    }
    assert!(cases > 20_000);
    assert!(fell_back_two > 1_000); // the double fault really was exercised
}

#[test]
fn a_long_life_of_crashes_damaged_slots_and_restarts_never_shows_a_mixed_tree() {
    let mut rng = Rng(2323);
    let mut db = Db::new(4);
    // content[t] = what the newest commit with id t wrote (ids repeat after
    // a fallback: the lost transaction's id is handed out again).
    let mut content: Vec<Vec<Entry>> = vec![Vec::new()];
    let mut oracle = Oracle::new();
    let mut held: Option<Held> = None; // one reader, to mix snapshots into the rule
    let (mut restarts, mut fallbacks) = (0, 0);

    for step in 0..4000u64 {
        let key = rng.below(40);
        let is_put = rng.below(5) < 3;
        let before = db.current.txn_id;
        if rng.below(6) == 0 {
            // Half of the crashes hit the page writes, half the meta write.
            let fuse = if rng.below(2) == 0 { 4 } else { 44 };
            db.crash_after = Some(rng.below(fuse) as usize);
        }
        let result = if is_put { db.put(key, step) } else { db.delete(key) };
        let restart = match result {
            Ok(_) => {
                db.crash_after = None; // the commit was shorter than the fuse
                if db.current.txn_id != before {
                    if is_put {
                        oracle.put(key, step);
                    } else {
                        oracle.delete(key);
                    }
                    let t = db.current.txn_id as usize;
                    assert!(t <= content.len());
                    content.truncate(t);
                    content.push(oracle_all(&oracle));
                }
                rng.below(25) == 0 // sometimes the power just goes
            }
            Err(e) => {
                assert_eq!(e, TxnError::Crashed);
                true
            }
        };

        if restart {
            // One slot may rot, as long as the other one is readable.
            let slots = &mut db.store.meta_slots;
            if slots.iter().all(|s| Meta::decode(s).is_some()) && rng.below(2) == 0 {
                let which = rng.below(2) as usize;
                damage(&mut slots[which], Damage::BitFlip, rng.below(256) as usize);
            }
            let want = newest_readable(&db).unwrap();
            db.reopen().unwrap();
            restarts += 1;
            if want < before {
                fallbacks += 1;
            }
            assert_eq!(db.current.txn_id, want);
            assert_eq!(all(db.view()), content[want as usize]);
            oracle = Oracle::new();
            for e in &content[want as usize] {
                oracle.put(e.key, e.value);
            }
            held = None; // a restart forgets its readers
        }
        db.validate().unwrap();
        assert_eq!(all(db.view()), oracle_all(&oracle));

        if let Some(h) = &held {
            assert_eq!(all(h.snap.view(&db)), h.saved);
            if rng.below(10) == 0 {
                db.release(h.snap);
                held = None;
            }
        } else if rng.below(8) == 0 {
            held = Some(Held {
                snap: db.snapshot(),
                saved: oracle_all(&oracle),
            });
        }
    }
    assert!(restarts > 300);
    assert!(fallbacks > 50);
}

#[test]
fn reopen_reports_a_tree_that_is_not_all_there_instead_of_walking_into_it() {
    // Each case changes the newest meta (a valid checksum is added
    // afterwards) or the pages: damage the checksum cannot see.
    type Forge = fn(&mut Meta, &mut Db);
    let forgeries: [Forge; 14] = [
        |m, _| m.root = PageId::from_index(500), // root outside the store
        |m, _| m.page_count = 1_000_000,         // a store that is not there
        |m, _| m.page_count = 3,                 // the root lies beyond the end
        |m, _| m.height = 4_000_000_000,         // would be a very deep recursion
        |m, _| m.height = 2,                     // leaves are deeper than that
        |m, _| m.height = 0,
        |m, _| m.count += 1,
        |m, _| m.root = PageId::NIL, // "empty", but with 12 keys
        |m, db| m.root = db.store.free[0], // a page of no tree (a stale leaf)
        |m, db| {
            // A cycle: the root's first child points back at the root.
            let child = db.store.slots[m.root.index()].node.internal().children[0].index();
            db.store.slots[child].node.internal_mut().children[0] = m.root;
        },
        |m, db| {
            db.store.slots[m.root.index()].node.internal_mut().children[1] = PageId::from_index(77);
        },
        |m, db| {
            db.store.slots[m.root.index()].node.internal_mut().children[1] = PageId::NIL;
        },
        |m, db| {
            // A page of this tree was overwritten by a later transaction:
            // what a stale slot looks like when its pages were reused.
            db.store.slots[m.root.index()].written_by = m.txn_id + 1;
        },
        |m, db| db.store.slots[m.root.index()].node.len = 99, // more keys than a node holds
    ];
    for forge in forgeries {
        let mut db = build_canonical();
        let mut m = db.current;
        forge(&mut m, &mut db);
        db.store.meta_slots[(m.txn_id % 2) as usize] = m.encode();
        let pages = db.store.page_count();
        assert_eq!(db.reopen(), Err(ReopenError::CorruptTree));
        // A failed restart changes nothing.
        assert_eq!(db.current.txn_id, 12);
        assert_eq!(db.store.page_count(), pages);
    }

    // A grown store whose new pages were never written: the slot names one.
    {
        let mut db = build_canonical();
        db.store.grow(20);
        let mut m = db.current;
        m.root = PageId::from_index(19);
        m.page_count = 20;
        m.height = 1;
        db.store.meta_slots[0] = m.encode();
        assert_eq!(db.reopen(), Err(ReopenError::CorruptTree));
    }

    // Random slots with a valid checksum: an error or a walkable tree,
    // never a panic, never a hang.
    let mut rng = Rng(77);
    let mut survived = 0;
    for _ in 0..3000 {
        let mut db = build_canonical();
        let m = Meta {
            txn_id: rng.below(30),
            root: if rng.below(10) == 0 {
                PageId::NIL
            } else {
                PageId::from_index(rng.below(16) as usize)
            },
            height: rng.below(5) as u32,
            count: rng.below(14),
            page_count: rng.below(16) as u32,
        };
        db.store.meta_slots[rng.below(2) as usize] = m.encode();
        match db.reopen() {
            Ok(()) => {
                survived += 1;
                assert_eq!(db.view().seek(0).count() as u64, db.current.count);
            }
            Err(e) => assert_eq!(e, ReopenError::CorruptTree),
        }
    }
    assert!(survived > 0 && survived < 3000);
}

// ---------------------------------------------------------- model tests

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
                saved: oracle_all(&oracle),
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
                assert_eq!(all(h.snap.view(&db)), h.saved);
            }
        }
    }
    while let Some(h) = held.pop() {
        db.release(h.snap);
    }
    db.validate().unwrap();
    // With no reader left, every page is in the tree, free, or kept for the
    // fallback root.
    assert_only_fallback_pending(&db);
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
            assert_eq!(all(txn.committed().view()), oracle_all(&saved));
            if batch % 5 == 4 {
                txn.abort();
                oracle = saved;
                assert_eq!(db.current, before);
            } else {
                txn.commit().unwrap();
            }
            assert_eq!(all(db.view()), oracle_all(&oracle));
            if batch % 3 == 0 {
                db.validate().unwrap();
            }
            batch += 1;
        }
        db.validate().unwrap();
        assert_only_fallback_pending(&db);
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
    // `put 13` as txn 13. Pages #0 #7 #11 are pending (old path), #2 #6 #12
    // are the new path, #3 #5 #8 #9 #10 are shared by both roots. The
    // fallback root (`previous`) is txn 12, the same root as the snapshot.
    type Corrupt = fn(&mut Db, Snapshot);
    let cases: [(Violation, Corrupt); 14] = [
        (Violation::LivePageModified, |db, _| {
            // "Someone" rewrote a shared page in place as transaction 13:
            // legal for the current root, a lie to the snapshot of 12.
            db.store.slots[8].written_by = 13;
        }),
        (Violation::ReachablePageIsFree, |db, _| {
            db.store.release(PageId::from_index(9)); // a live leaf becomes writable
        }),
        (Violation::ReachablePageIsFree, |db, _| {
            // Reclaim too early: pretend nobody needs the old root.
            let snapshots = std::mem::take(&mut db.snapshots);
            let previous = db.previous.take();
            db.reclaim();
            db.snapshots = snapshots;
            db.previous = previous;
        }),
        (Violation::ReachablePageIsFree, |db, snap| {
            // The rule without its second half: no reader is left, so the
            // pages txn 13 replaced are freed at once. But meta slot 0 still
            // names txn 12, and its tree now has holes.
            db.release(snap);
            let previous = db.previous.take();
            db.reclaim();
            db.previous = previous;
        }),
        (Violation::FallbackUnprotected, |db, _| {
            db.previous = None; // slot 0 can still be chosen by a restart
        }),
        (Violation::SnapshotPageUnprotected, |db, _| {
            for p in &mut db.pending {
                p.freed_by = 12; // "freed by 12" would be releasable
            }
        }),
        (Violation::FreeListCorrupt, |db, _| {
            db.store.free.push(PageId::from_index(3)); // listed but live
        }),
        (Violation::PendingCorrupt, |db, _| {
            db.pending[0].page = PageId::from_index(10); // a page of the current tree
        }),
        (Violation::PageLeak, |db, _| {
            db.pending.pop(); // forgotten: neither reachable, pending nor free
            db.snapshots.clear();
        }),
        (Violation::PageReachedTwice, |db, _| {
            // The sibling-link disease: one leaf under two parents.
            let root = db.current.root.index();
            let left = db.store.slots[root].node.internal().children[0].index();
            let children = &mut db.store.slots[left].node.internal_mut().children;
            children[1] = children[0];
        }),
        (Violation::KeyOutOfBounds, |db, _| {
            db.store.slots[12].node.keys[2] = 99; // leaf (10 12 13) under [6 10 | 15)
        }),
        (Violation::WrongCount, |db, _| {
            db.snapshots[0].snap.count += 1;
        }),
        (Violation::BadMeta, |db, _| {
            db.store.meta_slots[1][3] ^= 0x40; // newest slot torn: current is no longer the winner
        }),
        (Violation::DanglingChild, |db, _| {
            let root = db.current.root.index();
            db.store.slots[root].node.internal_mut().children[1] = PageId::from_index(500);
        }),
    ];
    for (expected, corrupt) in cases {
        let mut db = build_canonical();
        let snap = db.snapshot();
        db.put(13, 1300).unwrap();
        db.validate().unwrap();
        corrupt(&mut db, snap);
        assert_eq!(db.validate(), Err(expected));
    }
}
