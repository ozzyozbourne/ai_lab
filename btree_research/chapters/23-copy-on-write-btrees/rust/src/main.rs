//! Demo program of chapter 23. Its stdout is exactly ../expected_output.txt
//! (checked by the test at the bottom) and is identical to the Zig program's.

use std::io::{self, Write};

use ch23_copy_on_write_btrees::ops::{Config, Entry, Op, OpStream, Oracle, Weights};
use ch23_copy_on_write_btrees::{CommitInfo, Cursor, Db, Meta, Snapshot, TxnError, dump};

/// Canonical hand example of chapters 03 to 08.
const CANONICAL: [u64; 12] = [10, 20, 5, 6, 12, 30, 7, 17, 3, 25, 1, 15];

/// No page budget is set in this program, so transactions cannot fail.
const NO_BUDGET: &str = "no page budget set";

fn main() -> io::Result<()> {
    let mut out = io::BufWriter::new(io::stdout().lock());
    run(&mut out)?;
    out.flush()
}

/// Zig prints an optional with `{?d}`: the number, or `null`.
fn opt(v: Option<u64>) -> String {
    v.map_or("null".to_string(), |v| v.to_string())
}

fn run(w: &mut dyn Write) -> io::Result<()> {
    let mut db = Db::new(4);

    writeln!(
        w,
        "== 1. Build: canonical keys, M = 4, one transaction per put =="
    )?;
    for key in CANONICAL {
        let mut txn = db.begin();
        txn.put(key, key * 100).expect(NO_BUDGET);
        let info = txn.commit().expect(NO_BUDGET);
        write!(w, "put {key:<2}")?;
        print_commit(w, info, &db)?;
    }
    dump::dump(db.view(), db.current.txn_id, w)?;
    print_store(w, &db)?;
    db.validate().expect("valid");

    writeln!(
        w,
        "\n== 2. Path copying: a snapshot keeps the old root alive =="
    )?;
    let snap = db.snapshot();
    writeln!(
        w,
        "snapshot taken at txn {} (root #{})",
        snap.id,
        snap.root.index()
    )?;
    {
        let mut txn = db.begin();
        txn.put(13, 1300).expect(NO_BUDGET);
        let info = txn.commit().expect(NO_BUDGET);
        write!(w, "put 13")?;
        print_commit(w, info, &db)?;
    }
    writeln!(w, "old tree, still readable through the snapshot:")?;
    dump::dump(snap.view(&db), snap.id, w)?;
    writeln!(w, "new tree:")?;
    dump::dump(db.view(), db.current.txn_id, w)?;
    print_sharing(w, &db, snap)?;
    print_store(w, &db)?;
    db.validate().expect("valid");

    writeln!(
        w,
        "\n== 3. Two readers, two answers; range without sibling links =="
    )?;
    writeln!(
        w,
        "snapshot: get 13 = {}, {} keys",
        opt(snap.view(&db).get(13)),
        snap.count
    )?;
    writeln!(
        w,
        "current : get 13 = {}, {} keys",
        opt(db.get(13)),
        db.len()
    )?;
    write!(w, "snapshot range [6, 20):")?;
    for e in snap.view(&db).range(6, 20) {
        write!(w, " {}", e.key)?;
    }
    write!(w, "\ncurrent  range [6, 20):")?;
    for e in db.range(6, 20) {
        write!(w, " {}", e.key)?;
    }
    writeln!(w)?;

    writeln!(w, "\n== 4. Freed pages wait for the snapshot ==")?;
    for key in [6, 7] {
        let mut txn = db.begin();
        txn.delete(key).expect(NO_BUDGET);
        let info = txn.commit().expect(NO_BUDGET);
        write!(w, "delete {key}")?;
        print_commit(w, info, &db)?;
    }
    print_store(w, &db)?;
    writeln!(
        w,
        "snapshot still sees {} keys, get 6 = {}",
        snap.count,
        opt(snap.view(&db).get(6))
    )?;
    db.validate().expect("valid");
    let second = db.retain(snap); // a second reader of the same root
    writeln!(
        w,
        "two handles on txn {}; release the first : {} pages released",
        snap.id,
        db.release(snap)
    )?;
    writeln!(
        w,
        "                       release the second: {} pages move from pending to the free list",
        db.release(second)
    )?;
    print_store(w, &db)?;
    {
        let mut txn = db.begin();
        txn.put(8, 800).expect(NO_BUDGET);
        let info = txn.commit().expect(NO_BUDGET);
        write!(w, "put 8 ")?;
        print_commit(w, info, &db)?;
    }
    dump::dump(db.view(), db.current.txn_id, w)?;
    print_store(w, &db)?;
    db.validate().expect("valid");

    writeln!(w, "\n== 5. A transaction with several writes; abort ==")?;
    for do_commit in [false, true] {
        let mut txn = db.begin();
        for key in [26, 27, 28] {
            txn.put(key, key * 100).expect(NO_BUDGET);
            writeln!(
                w,
                "  put {key}: {} dirty pages, {} copied so far",
                txn.dirty_count(),
                txn.info().copied
            )?;
        }
        writeln!(
            w,
            "  inside the txn: get 27 = {}; outside: get 27 = {}",
            opt(txn.get(27)),
            opt(txn.committed().get(27))
        )?;
        if do_commit {
            let info = txn.commit().expect(NO_BUDGET);
            write!(w, "commit")?;
            print_commit(w, info, &db)?;
        } else {
            txn.abort();
            writeln!(
                w,
                "abort : current is still txn {}, root #{}, get 27 = {}",
                db.current.txn_id,
                db.current.root.index(),
                opt(db.get(27))
            )?;
            print_store(w, &db)?;
        }
    }
    dump::dump(db.view(), db.current.txn_id, w)?;
    db.validate().expect("valid");

    writeln!(w, "\n== 6. The two-slot metapage: restarts after damage ==")?;
    print_meta(w, &db)?;
    // (a) A torn meta write. Commits alternate, so txn 18 writes slot 0.
    crashing_put(&mut db, 9, 12);
    writeln!(
        w,
        "put 9: power fails in the middle of the meta write of txn 18 (slot 0). Restart:"
    )?;
    print_meta(w, &db)?;
    db.reopen().expect("one slot is intact");
    writeln!(
        w,
        "get 9 = {}, {} keys (txn 18 never happened; txn 17 is complete)",
        opt(db.get(9)),
        db.len()
    )?;
    print_store(w, &db)?;
    db.validate().expect("valid");
    {
        let mut txn = db.begin();
        txn.put(9, 900).expect(NO_BUDGET);
        let info = txn.commit().expect(NO_BUDGET);
        write!(w, "put 9 ")?;
        print_commit(w, info, &db)?;
    }
    print_store(w, &db)?;
    // (b) Two faults at once: txn 19 is in flight, and the slot of the
    // newest commit (txn 18, slot 0) cannot be read any more.
    let pages = crashing_put(&mut db, 4, 0);
    db.store.meta_slots[0][8] ^= 0xFF; // damage the root field
    writeln!(
        w,
        "put 4: power fails after the {pages} page writes of txn 19, before its meta write."
    )?;
    writeln!(
        w,
        "On top of that, slot 0 (txn 18, the newest commit) has become unreadable. Restart:"
    )?;
    print_meta(w, &db)?;
    db.reopen().expect("one slot is intact");
    dump::dump(db.view(), db.current.txn_id, w)?;
    writeln!(
        w,
        "get 9 = {}, get 4 = {} (txn 18 is lost with its slot; txn 17 is complete, although txn 19 had written pages)",
        opt(db.get(9)),
        opt(db.get(4))
    )?;
    print_store(w, &db)?;
    db.validate().expect("valid");

    model_run(w)
}

/// `put key` as a transaction whose commit loses power after all of its page
/// writes and `meta_bytes` bytes of its meta slot. Returns the number of
/// page writes. The caller restarts with `db.reopen`.
fn crashing_put(db: &mut Db, key: u64, meta_bytes: usize) -> usize {
    // A dry run tells how many pages the commit will write.
    let mut txn = db.begin();
    txn.put(key, key * 100).expect(NO_BUDGET);
    let pages = txn.dirty_count();
    txn.abort();
    db.crash_after = Some(pages + meta_bytes);
    assert_eq!(db.put(key, key * 100), Err(TxnError::Crashed));
    pages
}

fn print_commit(w: &mut dyn Write, info: CommitInfo, db: &Db) -> io::Result<()> {
    writeln!(
        w,
        " -> txn {:<2} copied {} reused {} fresh {} | freed {} released {} | root #{}",
        info.txn_id,
        info.copied,
        info.reused,
        info.fresh,
        info.freed,
        info.released,
        db.current.root.index()
    )
}

fn print_store(w: &mut dyn Write, db: &Db) -> io::Result<()> {
    write!(w, "store: {} pages | free:", db.store.page_count())?;
    for id in &db.store.free {
        write!(w, " #{}", id.index())?;
    }
    if db.store.free.is_empty() {
        write!(w, " -")?;
    }
    write!(w, " | pending:")?;
    for p in &db.pending {
        write!(w, " #{}(txn {})", p.page.index(), p.freed_by)?;
    }
    if db.pending.is_empty() {
        write!(w, " -")?;
    }
    writeln!(w)
}

/// Which pages the snapshot's tree and the current tree have in common.
fn print_sharing(w: &mut dyn Write, db: &Db, snap: Snapshot) -> io::Result<()> {
    let n = db.store.page_count();
    let mut old = vec![false; n];
    let mut new = vec![false; n];
    dump::mark_reachable(snap.view(db), &mut old);
    dump::mark_reachable(db.view(), &mut new);
    let labels = [
        "shared by both roots:",
        "only the old root   :",
        "only the new root   :",
    ];
    for (which, label) in labels.iter().enumerate() {
        write!(w, "{label}")?;
        for i in 0..n {
            let show = match which {
                0 => old[i] && new[i],
                1 => old[i] && !new[i],
                _ => new[i] && !old[i],
            };
            if show {
                write!(w, " #{i}")?;
            }
        }
        writeln!(w)?;
    }
    Ok(())
}

fn print_meta(w: &mut dyn Write, db: &Db) -> io::Result<()> {
    for (i, slot) in db.store.meta_slots.iter().enumerate() {
        write!(w, "  slot {i}: ")?;
        match Meta::decode(slot) {
            Some(m) => write!(
                w,
                "txn {}, root #{}, height {}, {} keys, {} pages, crc {:08x}  valid",
                m.txn_id,
                m.root.index(),
                m.height,
                m.count,
                m.page_count,
                Meta::checksum(slot)
            )?,
            None => write!(
                w,
                "stored crc {:08x} does not match  INVALID",
                Meta::checksum(slot)
            )?,
        }
        writeln!(w)?;
    }
    let m = Meta::pick(&db.store.meta_slots).expect("one slot is intact");
    writeln!(w, "  reader picks txn {}", m.txn_id)
}

struct Held {
    snap: Snapshot,
    saved: Vec<Entry>,
}

/// Seeded model run: one transaction per write, snapshots taken along the
/// way and compared against saved copies of the oracle.
fn model_run(w: &mut dyn Write) -> io::Result<()> {
    writeln!(
        w,
        "\n== 7. Model run: 3000 operations, snapshots against saved oracle copies =="
    )?;
    for order in [4, 5, 8] {
        let mut db = Db::new(order);
        let mut oracle = Oracle::new();
        let mut held: Vec<Held> = Vec::new();
        let mut mismatches = 0;
        let mut snapshots_checked = 0;
        let mut peak_pending = 0;
        let stream = OpStream::new(Config {
            seed: 23,
            count: 3000,
            key_space: 200,
            weights: Weights::default(),
        });
        for (i, op) in stream.enumerate() {
            match op {
                Op::Put { key, value } => {
                    if db.put(key, value).expect(NO_BUDGET) != oracle.put(key, value) {
                        mismatches += 1;
                    }
                }
                Op::Delete { key } => {
                    if db.delete(key).expect(NO_BUDGET) != oracle.delete(key) {
                        mismatches += 1;
                    }
                }
                Op::Get { key } => {
                    if db.get(key) != oracle.get(key) {
                        mismatches += 1;
                    }
                }
                Op::Range { lo, hi } => {
                    mismatches += count_mismatches(db.view().seek(lo), Some(hi), oracle.range(lo, hi));
                }
            }
            peak_pending = peak_pending.max(db.pending.len());
            if i % 100 == 0 {
                // Keep at most three snapshots: drop the oldest first.
                if held.len() == 3 {
                    db.release(held.remove(0).snap);
                }
                held.push(Held {
                    snap: db.snapshot(),
                    // Every key is below 200, so the exclusive bound loses nothing.
                    saved: oracle.range(0, u64::MAX).to_vec(),
                });
            }
            if i % 50 == 49 {
                // Every held snapshot must still read exactly what was saved.
                for h in &held {
                    mismatches += count_mismatches(h.snap.view(&db).seek(0), None, &h.saved);
                    snapshots_checked += 1;
                }
                db.validate().expect("valid");
            }
        }
        let pages_at_end = db.store.page_count();
        while let Some(h) = held.pop() {
            db.release(h.snap);
        }
        db.validate().expect("valid");
        let s = db.stats;
        writeln!(
            w,
            "M={order:<2} keys={} height={} commits={} | pages: store={pages_at_end} copied={} reused={} fresh={} released={} peak pending={peak_pending} | snapshot checks={snapshots_checked} mismatches={mismatches}",
            db.len(),
            db.current.height,
            s.commits,
            s.pages_copied,
            s.pages_reused,
            s.pages_fresh,
            s.pages_released,
        )?;
    }
    Ok(())
}

/// Compares what the cursor yields, up to `hi` (exclusive; `None` = to the
/// end of the tree), with `expected`.
fn count_mismatches(cursor: Cursor<'_>, hi: Option<u64>, expected: &[Entry]) -> usize {
    let mut mismatches = 0;
    let mut i = 0;
    for e in cursor {
        if hi.is_some_and(|hi| e.key >= hi) {
            break;
        }
        if expected.get(i).is_none_or(|x| e.key != x.key || e.value != x.value) {
            mismatches += 1;
        }
        i += 1;
    }
    mismatches + expected.len().saturating_sub(i)
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
