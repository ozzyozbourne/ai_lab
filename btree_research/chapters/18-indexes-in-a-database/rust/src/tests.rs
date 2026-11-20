//! Tests of the table engine: fixed scenarios, the cost claims of the chapter
//! as assertions, a seeded model test of both layouts against a plain list of
//! rows, node-budget failure with rollback, and proof that `validate` catches
//! an index that disagrees with the table.

use crate::cursor::Cursor;
use crate::heap::Slot;
use crate::prng::SplitMix64;
use crate::row::{self, Row};
use crate::table::{InsertError, Layout, Table, ValidateError};

const LAYOUTS: [Layout; 2] = [Layout::Clustered, Layout::Heap];

const fn r(id: u32, customer: u16, day: u16, amount: u16, code: u16) -> Row {
    Row {
        id,
        customer,
        day,
        amount,
        code,
    }
}

/// The 12 rows of the demo program: ids are the canonical keys of chapters
/// 03 to 08, in the canonical order.
const DEMO_ROWS: [Row; 12] = [
    r(10, 7, 12, 250, 141),
    r(20, 3, 4, 40, 107),
    r(5, 7, 12, 75, 163),
    r(6, 9, 2, 300, 118),
    r(12, 7, 3, 120, 155),
    r(30, 3, 9, 90, 102),
    r(7, 7, 21, 35, 129),
    r(17, 9, 15, 510, 170),
    r(3, 3, 4, 60, 111),
    r(25, 7, 17, 125, 134),
    r(1, 3, 28, 999, 148),
    r(15, 9, 2, 45, 126),
];

fn build_demo(layout: Layout) -> Table {
    let mut table = Table::new(layout, 4);
    for row in DEMO_ROWS {
        table.insert(row).unwrap();
    }
    table
}

fn ids(rows: &[Row]) -> Vec<u32> {
    rows.iter().map(|row| row.id).collect()
}

#[test]
fn point_lookup_the_clustered_descent_ends_at_the_row_the_heap_needs_one_more_read() {
    for layout in LAYOUTS {
        let table = build_demo(layout);
        table.validate().unwrap();
        let before = table.counters.get();
        assert_eq!(table.get_by_id(17), Some(DEMO_ROWS[7]));
        assert_eq!(table.get_by_id(18), None);
        let cost = table.counters.get().minus(before);
        assert_eq!(cost.descents, 2);
        // Only the hit on the heap layout leaves the index.
        assert_eq!(cost.row_fetches, usize::from(layout == Layout::Heap));
        assert_eq!(cost.heap_reads, cost.row_fetches);
    }
}

#[test]
fn secondary_index_k_rows_cost_k_extra_descents_clustered_or_k_heap_reads_heap() {
    let mut rows = Vec::new();
    for layout in LAYOUTS {
        let table = build_demo(layout);
        let before = table.counters.get();
        table.fetch_scan(&mut rows, row::customer_range(7));
        // Index order is (day, locator). The two rows of day 12 are ordered by
        // row id in the clustered layout and by arrival (TID) in the heap.
        let expected = match layout {
            Layout::Clustered => [12, 5, 10, 25, 7],
            Layout::Heap => [12, 10, 5, 25, 7],
        };
        assert_eq!(ids(&rows), expected);
        let cost = table.counters.get().minus(before);
        assert_eq!(cost.row_fetches, 5);
        assert_eq!(cost.index_entries, 5);
        match layout {
            Layout::Clustered => {
                assert_eq!(cost.descents, 1 + 5);
                assert_eq!(cost.heap_reads, 0);
            }
            Layout::Heap => {
                assert_eq!(cost.descents, 1);
                assert_eq!(cost.heap_reads, 5);
            }
        }
    }
}

#[test]
fn covering_scan_never_leaves_the_index_in_either_layout() {
    let mut keys = Vec::new();
    for layout in LAYOUTS {
        let table = build_demo(layout);
        let before = table.counters.get();
        table.index_only_scan(&mut keys, row::customer_range(7));
        assert_eq!(keys.len(), 5);
        for (key, day) in keys.iter().zip([3, 12, 12, 17, 21]) {
            assert_eq!(row::key_customer(*key), 7);
            assert_eq!(row::key_day(*key), day);
        }
        let cost = table.counters.get().minus(before);
        assert_eq!(cost.descents, 1);
        assert_eq!(cost.row_fetches, 0);
        assert_eq!(cost.heap_reads, 0);
        // The clustered index covers the primary key as well: its locator IS the id.
        if layout == Layout::Clustered {
            assert_eq!(row::key_locator(keys[0]), 12);
        }
    }
}

#[test]
fn prefix_scans_leading_column_leading_column_plus_range_and_a_non_prefix() {
    let table = build_demo(Layout::Clustered);
    let mut rows = Vec::new();
    let mut scan = |range| {
        table.fetch_scan(&mut rows, range);
        ids(&rows)
    };
    assert_eq!(scan(row::customer_range(7)), [12, 5, 10, 25, 7]);
    assert_eq!(scan(row::customer_days_range(7, 10, 20)), [5, 10, 25]);
    assert_eq!(scan(row::customer_days_range(7, 12, 12)), [5, 10]);
    assert_eq!(scan(row::customer_days_range(7, 13, 16)), []);
    assert_eq!(scan(row::customer_range(8)), []);
    assert_eq!(scan(row::customer_range(9)), [6, 15, 17]);

    // day alone is not a prefix: the whole index is read to find 2 entries.
    let before = table.counters.get();
    assert_eq!(table.count_on_day(12), 2);
    assert_eq!(table.counters.get().minus(before).index_entries, 12);
    // ... while the two-column prefix reads exactly the 2 it returns.
    let before_prefix = table.counters.get();
    let mut keys = Vec::new();
    table.index_only_scan(&mut keys, row::customer_days_range(7, 12, 12));
    assert_eq!(table.counters.get().minus(before_prefix).index_entries, 2);
}

#[test]
fn unique_constraint_and_primary_key_reject_duplicates_and_change_nothing() {
    for layout in LAYOUTS {
        let mut table = build_demo(layout);
        let pages_before = table.heap.page_count();

        let before = table.counters.get();
        assert_eq!(
            table.insert(r(40, 3, 1, 10, 129)),
            Err(InsertError::DuplicateCode)
        );
        // Rejected after two descents (id check, code check), before any write.
        assert_eq!(table.counters.get().minus(before).descents, 2);
        assert_eq!(
            table.insert(r(12, 3, 1, 10, 500)),
            Err(InsertError::DuplicatePrimaryKey)
        );
        // The id is checked first, so a row that violates both reports the id.
        assert_eq!(
            table.insert(r(12, 3, 1, 10, 129)),
            Err(InsertError::DuplicatePrimaryKey)
        );

        assert_eq!(table.rows, 12);
        assert_eq!(table.heap.page_count(), pages_before);
        assert_eq!(table.get_by_id(40), None);
        assert_eq!(table.get_by_code(500), None);
        assert_eq!(table.get_by_code(129).unwrap().id, 7);
        table.validate().unwrap();

        // Deleting the holder frees the code for somebody else.
        assert!(table.delete(7));
        assert!(!table.delete(7));
        table.insert(r(40, 3, 1, 10, 129)).unwrap();
        assert_eq!(table.get_by_code(129).unwrap().id, 40);
        table.validate().unwrap();
    }
}

#[test]
fn heap_a_deleted_row_leaves_a_dead_slot_and_every_other_tid_still_works() {
    let mut table = build_demo(Layout::Heap);
    assert_eq!(table.heap.page_count(), 3);
    assert!(table.delete(5)); // TID 2 = (0,3)
    assert_eq!(table.heap.page_slots(0)[2], Slot::Dead);
    assert_eq!(table.heap.live_rows, 11);
    for row in DEMO_ROWS {
        if row.id == 5 {
            continue;
        }
        assert_eq!(table.get_by_id(row.id), Some(row));
        assert_eq!(table.get_by_code(row.code), Some(row));
    }
    table.validate().unwrap();
}

// ------------------------------------------------------------- model test

/// The oracle: every row in arrival order, searched linearly. `seq` is the
/// arrival number, which is the order of TIDs in the heap layout.
#[derive(Default)]
struct Oracle {
    items: Vec<(Row, usize)>,
    next_seq: usize,
}

impl Oracle {
    fn find(&self, id: u32) -> Option<usize> {
        self.items.iter().position(|(row, _)| row.id == id)
    }

    fn has_code(&self, code: u16) -> bool {
        self.items.iter().any(|(row, _)| row.code == code)
    }

    /// Rows of `customer` with day in [lo, hi], in the order the index of
    /// the given layout returns them: (day, id) or (day, arrival).
    fn select(&self, layout: Layout, customer: u16, lo: u16, hi: u16) -> Vec<Row> {
        let mut out: Vec<(Row, usize)> = self
            .items
            .iter()
            .copied()
            .filter(|(row, _)| row.customer == customer && (lo..=hi).contains(&row.day))
            .collect();
        out.sort_by_key(|&(row, seq)| match layout {
            Layout::Clustered => (row.day, row.id as usize),
            Layout::Heap => (row.day, seq),
        });
        out.into_iter().map(|(row, _)| row).collect()
    }
}

fn model_test(layout: Layout, order: usize, seed: u64, ops: usize) {
    let mut table = Table::new(layout, order);
    let mut oracle = Oracle::default();
    // The per-query buffers: cleared by every query, capacity kept.
    let mut rows = Vec::new();
    let mut keys = Vec::new();
    let mut rng = SplitMix64::new(seed);

    for op_index in 0..ops {
        let id = rng.below(300) as u32;
        match rng.below(10) {
            0..=4 => {
                // insert; small ranges so both kinds of duplicate happen
                let row = Row {
                    id,
                    customer: rng.below(8) as u16,
                    day: rng.below(20) as u16,
                    amount: rng.below(1000) as u16,
                    code: rng.below(400) as u16,
                };
                let expected = if oracle.find(id).is_some() {
                    Err(InsertError::DuplicatePrimaryKey)
                } else if oracle.has_code(row.code) {
                    Err(InsertError::DuplicateCode)
                } else {
                    Ok(())
                };
                assert_eq!(table.insert(row), expected);
                if expected.is_ok() {
                    oracle.items.push((row, oracle.next_seq));
                    oracle.next_seq += 1;
                }
            }
            5..=6 => {
                // delete
                let at = oracle.find(id);
                assert_eq!(table.delete(id), at.is_some());
                if let Some(i) = at {
                    oracle.items.remove(i);
                }
            }
            7 => {
                // point lookups by both unique keys
                let expected = oracle.find(id).map(|i| oracle.items[i].0);
                assert_eq!(table.get_by_id(id), expected);
                if let Some(row) = expected {
                    assert_eq!(table.get_by_code(row.code), Some(row));
                }
            }
            _ => {
                // prefix scan, fetched and index-only
                let customer = rng.below(9) as u16;
                let d1 = rng.below(20) as u16;
                let d2 = rng.below(20) as u16;
                let lo = d1.min(d2);
                let hi = if rng.chance(1, 3) {
                    u16::MAX
                } else {
                    d1.max(d2)
                };
                let expected = oracle.select(layout, customer, lo, hi);
                let range = row::customer_days_range(customer, lo, hi);
                table.fetch_scan(&mut rows, range);
                table.index_only_scan(&mut keys, range);
                assert_eq!(rows, expected);
                let days: Vec<u16> = keys.iter().map(|&key| row::key_day(key)).collect();
                let expected_days: Vec<u16> = expected.iter().map(|row| row.day).collect();
                assert_eq!(days, expected_days);
                let on_day = oracle.items.iter().filter(|(row, _)| row.day == lo).count();
                assert_eq!(table.count_on_day(lo), on_day);
            }
        }
        assert_eq!(table.rows, oracle.items.len());
        if op_index % 64 == 0 {
            table.validate().unwrap();
        }
    }
    table.validate().unwrap();
}

#[test]
fn model_both_layouts_agree_with_a_plain_list_of_rows() {
    for layout in LAYOUTS {
        for order in [3, 4, 16] {
            model_test(layout, order, 18, 6000);
            model_test(layout, order, 1800 + order as u64, 3000);
        }
    }
}

// ------------------------------------------------------ node budget failure

#[test]
fn insert_under_a_node_budget_the_row_is_in_all_three_trees_or_in_none() {
    for layout in LAYOUTS {
        // Starve one tree at a time, at every possible size, so that the
        // failure arrives before, between and after the other two `put`s.
        for starved in 0..3 {
            let mut failures = 0;
            for budget in 0..40 {
                let mut budgets = [usize::MAX; 3];
                budgets[starved] = budget;
                let mut table = Table::with_node_budgets(layout, 3, budgets);
                for i in 0..40u32 {
                    let row = r(i * 7 % 40, (i % 3) as u16, (i % 5) as u16, 1, i as u16);
                    let slots_before = slots_used(&table);
                    match table.insert(row) {
                        Ok(()) => continue,
                        Err(e) => assert_eq!(e, InsertError::OutOfNodes),
                    }
                    failures += 1;
                    // Logically unchanged: valid, and the failed row is nowhere.
                    table.validate().unwrap();
                    assert_eq!(table.rows, i as usize);
                    assert_eq!(table.get_by_id(row.id), None);
                    assert_eq!(table.get_by_code(row.code), None);
                    // The heap append had succeeded before the tree failed:
                    // the rollback left exactly one dead slot behind.
                    if layout == Layout::Heap {
                        assert_eq!(slots_used(&table), slots_before + 1);
                        assert_eq!(table.heap.live_rows, table.rows);
                    }
                    break;
                }
            }
            assert!(failures > 10); // many different failure points were hit
        }
    }
}

fn slots_used(table: &Table) -> usize {
    (0..table.heap.page_count())
        .map(|p| table.heap.page_slots(p).len())
        .sum()
}

// ------------------------------------------------------ validate has teeth

#[test]
fn validate_catches_an_index_entry_without_a_row_and_a_row_without_an_entry() {
    for layout in LAYOUTS {
        let mut table = build_demo(layout);
        table.validate().unwrap();

        // An extra entry in the secondary index (counts no longer agree).
        let extra = row::customer_day_key(7, 13, 999);
        table.by_customer_day.put(extra, 0).unwrap();
        assert_eq!(table.validate(), Err(ValidateError::Inconsistent));
        table.by_customer_day.delete(extra);
        table.validate().unwrap();

        // Same count, but one entry files row 7 under the wrong day.
        let range = row::customer_days_range(7, 21, 21);
        let key = Cursor::seek(&table.by_customer_day, range, &table.counters)
            .next()
            .unwrap();
        let locator = row::key_locator(key);
        table.by_customer_day.delete(key);
        table
            .by_customer_day
            .put(row::customer_day_key(7, 22, locator), 0)
            .unwrap();
        assert_eq!(table.validate(), Err(ValidateError::Inconsistent));
    }
}
