//! Demo program of chapter 24. Its stdout is exactly ../expected_output.txt
//! (checked by the test at the bottom) and is identical to the Zig program's.

use std::io::{self, Write};

use ch24_mvcc_vacuum_and_page_deletion::ops::{Config, Entry, Op, OpStream, Oracle, Weights};
use ch24_mvcc_vacuum_and_page_deletion::{Cursor, DanglingLink, Db, VacuumOptions, dump};

fn main() -> io::Result<()> {
    let mut out = io::BufWriter::new(io::stdout().lock());
    run(&mut out)?;
    out.flush()
}

fn run(w: &mut dyn Write) -> io::Result<()> {
    versions_and_hints(w)?;
    vacuum_and_page_deletion(w)?;
    recycling_too_early(w)?;
    model_runs(w)
}

// ------------------------------------------------------------- helpers

/// No budget is set in this program, so `put` cannot fail.
const NO_BUDGET: &str = "no budget set";
/// Fewer than MAX_SNAPSHOTS are ever open at once here.
const FEW: &str = "few snapshots";
/// Nothing is recycled early except where section 6 says so.
const SAFE: &str = "no page recycled early";

const EVERYTHING: u64 = u64::MAX;

/// Zig prints an optional integer with `{?d}`: the number, or `null`.
fn optional(value: Option<u64>) -> String {
    value.map_or("null".to_string(), |v| v.to_string())
}

fn show(db: &Db, w: &mut dyn Write) -> io::Result<()> {
    write!(w, "  ")?;
    dump::dump(db, w)
}

/// `put` plus one line saying which transaction it was and what the index
/// had to do to make room.
fn put(db: &mut Db, w: &mut dyn Write, key: u64, value: u64) -> io::Result<()> {
    let before = db.index.stats;
    let old = db.put(key, value).expect(NO_BUDGET);
    write!(w, "put {key}={value}: xid {}", db.store.now)?;
    if let Some(o) = old {
        write!(w, ", ends the version holding {o}")?;
    }
    let s = db.index.stats;
    if s.simple_deleted > before.simple_deleted {
        let n = s.simple_deleted - before.simple_deleted;
        write!(w, "; page full: simple deletion removed {n}")?;
    }
    if s.bottom_up_deleted > before.bottom_up_deleted {
        let n = s.bottom_up_deleted - before.bottom_up_deleted;
        write!(w, "; page full: bottom-up deletion removed {n}")?;
    }
    if s.leaf_splits > before.leaf_splits {
        write!(w, "; page full: leaf split")?;
        if s.pages_reused > before.pages_reused {
            write!(w, " into a recycled page")?;
        }
    }
    writeln!(w)
}

fn delete(db: &mut Db, w: &mut dyn Write, key: u64) -> io::Result<()> {
    let old = db.delete(key);
    writeln!(
        w,
        "delete {key}: xid {}, sets xmax on the version holding {}; index untouched",
        db.store.now,
        optional(old)
    )
}

/// Scans everything under `snapshot` and reports what the scan cost.
fn scan(db: &mut Db, w: &mut dyn Write, name: &str, snapshot: u64) -> io::Result<()> {
    let before = db.reads;
    write!(w, "scan under {name}={snapshot}:")?;
    let mut cursor = Cursor::seek(db, snapshot, 0, EVERYTHING);
    while let Some(row) = cursor.next(db).expect(SAFE) {
        write!(w, " {}={}", row.key, row.value)?;
    }
    let r = db.reads;
    writeln!(
        w,
        " | heap fetches {}, skipped by hint {}, hints set {}",
        r.heap_fetches - before.heap_fetches,
        r.hint_skips - before.hint_skips,
        r.hints_set - before.hints_set
    )
}

fn vacuum(db: &mut Db, w: &mut dyn Write, options: VacuumOptions) -> io::Result<()> {
    let r = db.vacuum(options);
    writeln!(
        w,
        "vacuum (horizon {}): entries removed {}, pages unlinked {}, recycled {}, waiting {}",
        r.horizon, r.entries_removed, r.pages_unlinked, r.pages_recycled, r.pages_waiting
    )
}

fn outcome(done: bool) -> &'static str {
    if done { "done" } else { "refused" }
}

fn print_rows(w: &mut dyn Write, cursor: &mut Cursor, db: &mut Db, limit: usize) -> io::Result<()> {
    for _ in 0..limit {
        let Some(row) = cursor.next(db).expect(SAFE) else {
            break;
        };
        write!(w, " {}", row.key)?;
    }
    Ok(())
}

// ------------------------------------------------------------ sections

fn versions_and_hints(w: &mut dyn Write) -> io::Result<()> {
    let mut db = Db::new(4);

    writeln!(w, "== 1. Versions and snapshots (order M = 4: at most 3 entries per leaf) ==")?;
    for key in [10, 20, 30] {
        put(&mut db, w, key, key * 10)?;
    }
    let a = db.store.open_snapshot().expect(FEW);
    writeln!(w, "open snapshot A = {a}")?;
    put(&mut db, w, 20, 201)?;
    delete(&mut db, w, 30)?;
    let b = db.store.open_snapshot().expect(FEW);
    writeln!(w, "open snapshot B = {b}")?;
    show(&db, w)?;
    for key in [20, 30] {
        let under_a = optional(db.get(a, key).expect(SAFE));
        let under_b = optional(db.get(b, key).expect(SAFE));
        writeln!(w, "get {key}: under A = {under_a}, under B = {under_b}")?;
    }

    writeln!(w, "\n== 2. A scan leaves hints, but only for versions dead to everyone ==")?;
    scan(&mut db, w, "B", b)?;
    db.store.close_snapshot(a);
    writeln!(w, "close snapshot A: horizon is now {}", db.store.horizon())?;
    scan(&mut db, w, "B", b)?;
    show(&db, w)?;
    scan(&mut db, w, "B", b)?;

    writeln!(w, "\n== 3. A full leaf: garbage first, split last ==")?;
    put(&mut db, w, 25, 250)?;
    put(&mut db, w, 27, 270)?;
    show(&db, w)?;
    db.store.close_snapshot(b);
    writeln!(w, "close snapshot B: horizon is now {}", db.store.horizon())?;
    for value in [251, 252, 253] {
        put(&mut db, w, 25, value)?;
    }
    show(&db, w)?;
    let c = db.store.open_snapshot().expect(FEW);
    writeln!(w, "open snapshot C = {c}")?;
    for value in [254, 255] {
        put(&mut db, w, 25, value)?;
    }
    show(&db, w)?;
    db.store.close_snapshot(c);
    db.validate().expect("valid");
    let s = db.index.stats;
    writeln!(
        w,
        "totals: leaf splits {}, splits avoided {}, simple deletion {}, bottom-up deletion {}",
        s.leaf_splits, s.splits_avoided, s.simple_deleted, s.bottom_up_deleted
    )
}

/// Twelve rows 10..120, then rows 30..80 deleted while snapshot R is open.
fn build_with_deleted_range(db: &mut Db) -> u64 {
    for key in (10..=120).step_by(10) {
        db.put(key, key * 10).expect(NO_BUDGET);
    }
    let r = db.store.open_snapshot().expect(FEW);
    for key in (30..=80).step_by(10) {
        db.delete(key);
    }
    r
}

fn vacuum_and_page_deletion(w: &mut dyn Write) -> io::Result<()> {
    let mut db = Db::new(4);

    writeln!(w, "\n== 4. VACUUM removes only what the oldest snapshot cannot see ==")?;
    let r = build_with_deleted_range(&mut db);
    writeln!(w, "put 10..120 (xid 1..12), open snapshot R = {r}, delete 30..80 (xid 13..18)")?;
    show(&db, w)?;
    vacuum(&mut db, w, VacuumOptions { delete_pages: false })?;
    scan(&mut db, w, "R", r)?;
    db.store.close_snapshot(r);
    writeln!(w, "close snapshot R: horizon is now {}", db.store.horizon())?;
    vacuum(&mut db, w, VacuumOptions { delete_pages: false })?;
    show(&db, w)?;

    writeln!(w, "\n== 5. Deleting an empty leaf: half-dead, unlinked, recycled ==")?;
    let s = db.store.open_snapshot().expect(FEW);
    let mut cursor = Cursor::seek(&db, s, 0, EVERYTHING);
    write!(w, "open snapshot S = {s}; a scan under S returns:")?;
    print_rows(w, &mut cursor, &mut db, 2)?;
    let target = cursor.next_leaf;
    let neighbour = db.index.nodes.get(target).leaf().next;
    writeln!(w, " and pauses; the next page it will read is #{}", target.index())?;

    let marked = outcome(db.index.mark_half_dead(target));
    writeln!(w, "phase 1, mark #{} half-dead: {marked}", target.index())?;
    show(&db, w)?;
    let left = db.index.left_sibling(target);
    db.index.unlink_half_dead(&mut db.store, left, target);
    writeln!(w, "phase 2, unlink #{}: stamped with epoch {}", target.index(), db.store.now)?;
    show(&db, w)?;
    let horizon = db.store.horizon();
    writeln!(w, "recycle (horizon {horizon}): pages freed {}", db.index.recycle(horizon))?;
    let moved_before = db.reads.moved_right;
    write!(w, "the scan resumes:")?;
    print_rows(w, &mut cursor, &mut db, 100)?;
    writeln!(w, " | moved right past {} deleted page", db.reads.moved_right - moved_before)?;
    db.store.close_snapshot(s);
    let horizon = db.store.horizon();
    writeln!(
        w,
        "close snapshot S; recycle (horizon {horizon}): pages freed {}",
        db.index.recycle(horizon)
    )?;
    show(&db, w)?;
    put(&mut db, w, 11, 110)?;
    put(&mut db, w, 12, 120)?;
    show(&db, w)?;
    let marked = outcome(db.index.mark_half_dead(neighbour));
    writeln!(
        w,
        "mark #{} (the rightmost child of its parent) half-dead: {marked}",
        neighbour.index()
    )?;
    vacuum(&mut db, w, VacuumOptions::default())?;
    show(&db, w)?;
    db.validate().expect("valid");
    Ok(())
}

fn recycling_too_early(w: &mut dyn Write) -> io::Result<()> {
    let mut db = Db::new(4);

    writeln!(w, "\n== 6. Recycling too early breaks a scan ==")?;
    let r = build_with_deleted_range(&mut db);
    db.store.close_snapshot(r);
    db.vacuum(VacuumOptions { delete_pages: false });
    let s = db.store.open_snapshot().expect(FEW);
    let mut cursor = Cursor::seek(&db, s, 0, EVERYTHING);
    write!(w, "same tree as in section 5; the scan returns:")?;
    print_rows(w, &mut cursor, &mut db, 2)?;
    let target = cursor.next_leaf;
    writeln!(w, " and pauses before #{}", target.index())?;
    db.index.mark_half_dead(target);
    let left = db.index.left_sibling(target);
    db.index.unlink_half_dead(&mut db.store, left, target);
    writeln!(
        w,
        "#{} is deleted with stamp {}; snapshot S = {s} is older, but we recycle anyway (pages freed {})",
        target.index(),
        db.store.now,
        db.index.recycle_ignoring_snapshots()
    )?;
    let mut early = cursor.clone(); // a copy of the paused scan
    match early.next(&mut db) {
        Ok(_) => writeln!(w, "the scan resumes: (unexpectedly fine)")?,
        Err(DanglingLink) => writeln!(
            w,
            "the scan resumes at once: error.DanglingLink (the page is on the free list)"
        )?,
    }
    put(&mut db, w, 111, 1110)?;
    put(&mut db, w, 112, 1120)?;
    show(&db, w)?;
    write!(w, "the scan resumes after the split:")?;
    print_rows(w, &mut cursor, &mut db, 100)?;
    writeln!(w, " <- 90, 100 and 110 are missing, and nothing reports an error")
}

struct ModelConfig {
    name: &'static str,
    order: usize,
    bottom_up: bool,
    /// Run VACUUM after every this many operations (0 = never).
    vacuum_every: u64,
}

/// 20000 random operations against the sorted-array oracle. Current reads
/// use a snapshot taken for the one read. In addition one long-lived
/// snapshot at a time is held for 300 operations together with a copy of the
/// oracle taken at the same moment, and must still read exactly that copy.
fn model_runs(w: &mut dyn Write) -> io::Result<()> {
    writeln!(
        w,
        "\n== 7. Model run: 20000 random operations, long snapshots, different collectors =="
    )?;
    let config = |name, order, bottom_up, vacuum_every| ModelConfig { name, order, bottom_up, vacuum_every };
    let configs = [
        config("M=4  all collectors       ", 4, true, 250),
        config("M=4  no bottom-up         ", 4, false, 250),
        config("M=4  hints only, no vacuum", 4, false, 0),
        config("M=16 all collectors       ", 16, true, 250),
    ];
    for config in configs {
        model_run(w, &config)?;
    }
    Ok(())
}

fn model_run(w: &mut dyn Write, config: &ModelConfig) -> io::Result<()> {
    let mut db = Db::new(config.order);
    db.index.bottom_up = config.bottom_up;
    let mut oracle = Oracle::new();
    let mut frozen: Vec<Entry> = Vec::new(); // oracle copy of the long snapshot
    let mut long_snapshot = None;
    let stream = OpStream::new(Config { seed: 24, count: 20_000, key_space: 400, weights: Weights::default() });
    let mut mismatches = 0;
    for (step, op) in (0u64..).zip(stream) {
        match op {
            Op::Put { key, value } => {
                if db.put(key, value).expect(NO_BUDGET) != oracle.put(key, value) {
                    mismatches += 1;
                }
            }
            Op::Delete { key } => {
                if db.delete(key) != oracle.delete(key) {
                    mismatches += 1;
                }
            }
            Op::Get { key } => {
                let s = db.store.open_snapshot().expect(FEW);
                if db.get(s, key).expect(SAFE) != oracle.get(key) {
                    mismatches += 1;
                }
                db.store.close_snapshot(s);
            }
            Op::Range { lo, hi } => {
                let s = db.store.open_snapshot().expect(FEW);
                mismatches += compare_scan(&mut db, s, lo, hi, oracle.range(lo, hi));
                db.store.close_snapshot(s);
            }
        }
        if step % 500 == 100 {
            long_snapshot = Some(db.store.open_snapshot().expect(FEW));
            frozen.clear();
            frozen.extend_from_slice(oracle.range(0, u64::MAX));
        }
        if step % 500 == 400 {
            let s = long_snapshot.take().expect("opened 300 steps ago");
            mismatches += compare_scan(&mut db, s, 0, 400, &frozen);
            db.store.close_snapshot(s);
        }
        if config.vacuum_every != 0 && step % config.vacuum_every == config.vacuum_every - 1 {
            db.vacuum(VacuumOptions::default());
        }
    }
    db.validate().expect("valid");
    let s = db.index.stats;
    writeln!(
        w,
        "{} | rows {} entries {} pages {} slots {} | splits {} avoided {} | removed: simple {} bottom-up {} vacuum {} | pages unlinked {} recycled {} reused {} | mismatches {mismatches}",
        config.name,
        oracle.len(),
        db.index.count,
        db.index.nodes.live_count(),
        db.index.nodes.slot_count(),
        s.leaf_splits + s.internal_splits,
        s.splits_avoided,
        s.simple_deleted,
        s.bottom_up_deleted,
        s.vacuum_deleted,
        s.pages_unlinked,
        s.pages_recycled,
        s.pages_reused,
    )
}

/// Number of differences between a scan of [lo, hi) and the expected rows.
fn compare_scan(db: &mut Db, snapshot: u64, lo: u64, hi: u64, expected: &[Entry]) -> usize {
    let mut differences = 0;
    let mut cursor = Cursor::seek(db, snapshot, lo, hi);
    for e in expected {
        let row = cursor.next(db).expect(SAFE);
        if row.is_none_or(|r| r.key != e.key || r.value != e.value) {
            differences += 1;
        }
    }
    if cursor.next(db).expect(SAFE).is_some() {
        differences += 1;
    }
    differences
}

#[cfg(test)]
mod tests {
    #[test]
    fn run_prints_exactly_expected_output_txt() {
        let mut out = Vec::new();
        super::run(&mut out).unwrap();
        assert_eq!(String::from_utf8(out).unwrap(), include_str!("../../expected_output.txt"));
    }
}
