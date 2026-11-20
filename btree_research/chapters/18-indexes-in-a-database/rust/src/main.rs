//! Demo program of chapter 18. Its stdout is exactly ../expected_output.txt
//! (checked by the test at the bottom) and is identical to the Zig program's.

use std::io::{self, Write};

use ch18_indexes_in_a_database::heap::{SLOTS_PER_PAGE, Slot, tid_page, tid_slot};
use ch18_indexes_in_a_database::prng::SplitMix64;
use ch18_indexes_in_a_database::row::{self, KeyRange};
use ch18_indexes_in_a_database::{
    BPlusTree, Counters, InsertError, Layout, Locator, Row, Table, dump,
};

const fn r(id: u32, customer: u16, day: u16, amount: u16, code: u16) -> Row {
    Row {
        id,
        customer,
        day,
        amount,
        code,
    }
}

/// Ids are the canonical keys of chapters 03 to 08 in the canonical order, so
/// the clustered primary tree is the tree chapter 07 drew.
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

/// No node budget is set in this program, so `insert` cannot run out of nodes.
const NO_BUDGET: &str = "no node budget set";

fn main() -> io::Result<()> {
    let mut out = io::BufWriter::new(io::stdout().lock());
    run(&mut out)?;
    out.flush()
}

fn run(w: &mut dyn Write) -> io::Result<()> {
    // Tables own their trees and live as long as the program. Query results
    // live until the next query: two buffers, cleared and refilled each time.
    let mut rows: Vec<Row> = Vec::new();
    let mut keys: Vec<u64> = Vec::new();

    let mut tables = [
        Table::new(Layout::Clustered, 4),
        Table::new(Layout::Heap, 4),
    ];

    writeln!(w, "== 1. One table, two layouts ==")?;
    writeln!(
        w,
        "orders(id PRIMARY KEY, customer, day, amount, code UNIQUE); INDEX by_customer_day(customer, day)"
    )?;
    writeln!(
        w,
        "index key = columns, then locator, packed into one u64: customer:16 | day:16 | locator:32"
    )?;
    writeln!(
        w,
        "12 rows inserted with ids 10 20 5 6 12 30 7 17 3 25 1 15; every tree has order M = 4"
    )?;
    for t in &mut tables {
        for row in DEMO_ROWS {
            t.insert(row).expect(NO_BUDGET);
        }
        t.validate().expect("valid table");
        describe(w, t)?;
    }

    writeln!(
        w,
        "\n== 2. Point lookup: SELECT * FROM orders WHERE id = 17 =="
    )?;
    for t in &tables {
        let before = t.counters.get();
        let row = t.get_by_id(17).expect("row 17 exists");
        write!(w, "{}: ", name(t.layout))?;
        print_row(w, row)?;
        writeln!(w)?;
        print_cost(w, t.counters.get().minus(before))?;
    }

    writeln!(
        w,
        "\n== 3. Secondary index, then back to the row: SELECT * WHERE customer = 7 =="
    )?;
    for t in &tables {
        let before = t.counters.get();
        t.fetch_scan(&mut rows, row::customer_range(7));
        write!(w, "{}: ids", name(t.layout))?;
        for row in &rows {
            write!(w, " {}", row.id)?;
        }
        write!(w, ", amounts")?;
        for row in &rows {
            write!(w, " {}", row.amount)?;
        }
        writeln!(w)?;
        print_cost(w, t.counters.get().minus(before))?;
    }

    writeln!(
        w,
        "\n== 4. Covering (index-only) scan: SELECT day WHERE customer = 7 =="
    )?;
    for t in &tables {
        let before = t.counters.get();
        t.index_only_scan(&mut keys, row::customer_range(7));
        write!(w, "{}: days", name(t.layout))?;
        for &key in &keys {
            write!(w, " {}", row::key_day(key))?;
        }
        write!(w, ", locators in the entries")?;
        for &key in &keys {
            write!(w, " ")?;
            print_locator(w, t.layout, row::key_locator(key))?;
        }
        writeln!(w)?;
        print_cost(w, t.counters.get().minus(before))?;
    }
    writeln!(
        w,
        "clustered only: the locator is the id, so SELECT id, day is covered as well"
    )?;

    writeln!(
        w,
        "\n== 5. Composite key: which predicates are one contiguous run of the index? =="
    )?;
    let prefix_queries = [
        (
            "customer = 7 AND day BETWEEN 10 AND 20",
            row::customer_days_range(7, 10, 20),
        ),
        (
            "customer = 7 AND day = 12",
            row::customer_days_range(7, 12, 12),
        ),
        ("customer = 8", row::customer_range(8)),
    ];
    for (text, range) in prefix_queries {
        writeln!(w, "WHERE {text}")?;
        for t in &tables {
            let before = t.counters.get();
            t.fetch_scan(&mut rows, range);
            write!(w, "{}: ids", name(t.layout))?;
            for row in &rows {
                write!(w, " {}", row.id)?;
            }
            if rows.is_empty() {
                write!(w, " (none)")?;
            }
            writeln!(w)?;
            print_cost(w, t.counters.get().minus(before))?;
        }
    }
    writeln!(
        w,
        "WHERE day = 12   (not a prefix: the first column is free, so the whole index is read)"
    )?;
    for t in &tables {
        let before = t.counters.get();
        let count = t.count_on_day(12);
        writeln!(w, "{}: count {count}", name(t.layout))?;
        print_cost(w, t.counters.get().minus(before))?;
    }

    writeln!(
        w,
        "\n== 6. Unique constraint: probe the index before writing =="
    )?;
    let attempts = [
        r(40, 3, 1, 10, 129), // code of row 7
        r(12, 3, 1, 10, 500), // id taken
        r(40, 3, 1, 10, 500), // fine
    ];
    for row in attempts {
        writeln!(w, "INSERT id={} code={}", row.id, row.code)?;
        for t in &mut tables {
            let before = t.counters.get();
            let outcome = match t.insert(row) {
                Ok(()) => "ok",
                Err(InsertError::DuplicatePrimaryKey) => "rejected, duplicate primary key",
                Err(InsertError::DuplicateCode) => "rejected, duplicate code",
                Err(InsertError::OutOfNodes) => panic!("{NO_BUDGET}"),
            };
            writeln!(w, "{}: {outcome}; {} rows", name(t.layout), t.rows)?;
            print_cost(w, t.counters.get().minus(before))?;
            t.validate().expect("valid table");
        }
    }

    writeln!(
        w,
        "\n== 7. Delete: read the row first, its columns name the index entries =="
    )?;
    writeln!(w, "DELETE FROM orders WHERE id = 5")?;
    for t in &mut tables {
        let before = t.counters.get();
        let deleted = t.delete(5);
        writeln!(w, "{}: deleted {deleted}; {} rows", name(t.layout), t.rows)?;
        print_cost(w, t.counters.get().minus(before))?;
        write!(w, "  by_customer_day:")?;
        print_index(w, t.layout, &t.by_customer_day, KeyKind::CustomerDay)?;
        if t.layout == Layout::Heap {
            print_heap(w, t)?;
        }
        t.validate().expect("valid table");
    }

    scale_run(w, &mut rows, &mut keys)
}

fn name(layout: Layout) -> &'static str {
    match layout {
        Layout::Clustered => "clustered",
        Layout::Heap => "heap     ",
    }
}

fn print_row(w: &mut dyn Write, row: Row) -> io::Result<()> {
    write!(
        w,
        "id={} customer={} day={} amount={} code={}",
        row.id, row.customer, row.day, row.amount, row.code
    )
}

/// A row id prints as `#17`, a TID as `(page,slot)`.
fn print_locator(w: &mut dyn Write, layout: Layout, locator: Locator) -> io::Result<()> {
    match layout {
        Layout::Clustered => write!(w, "#{locator}"),
        Layout::Heap => write!(w, "({},{})", tid_page(locator), tid_slot(locator)),
    }
}

fn print_cost(w: &mut dyn Write, c: Counters) -> io::Result<()> {
    writeln!(
        w,
        "  cost: descents={} tree nodes={} index entries={} row fetches={} heap reads={} -> {} page reads",
        c.descents,
        c.tree_nodes,
        c.index_entries,
        c.row_fetches,
        c.heap_reads,
        c.page_reads()
    )
}

#[derive(Clone, Copy)]
enum KeyKind {
    CustomerDay,
    Column,
}

/// The entries of an index in leaf-chain order; ` | ` separates leaves.
fn print_index(
    w: &mut dyn Write,
    layout: Layout,
    tree: &BPlusTree,
    kind: KeyKind,
) -> io::Result<()> {
    write!(
        w,
        " height {}, {} nodes\n   ",
        tree.height,
        tree.nodes.live_count()
    )?;
    let mut id = tree.first_leaf;
    while !id.is_nil() {
        let n = tree.nodes.get(id);
        for &key in n.key_slice() {
            match kind {
                KeyKind::CustomerDay => {
                    write!(w, " ({},{},", row::key_customer(key), row::key_day(key))?;
                }
                KeyKind::Column => write!(w, " ({},", row::key_column(key))?,
            }
            print_locator(w, layout, row::key_locator(key))?;
            write!(w, ")")?;
        }
        id = n.leaf().next;
        if !id.is_nil() {
            write!(w, " |")?;
        }
    }
    writeln!(w)
}

fn print_heap(w: &mut dyn Write, t: &Table) -> io::Result<()> {
    for page in 0..t.heap.page_count() {
        write!(w, "  heap page {page}:")?;
        for (slot_index, slot) in t.heap.page_slots(page).iter().enumerate() {
            write!(w, " ({page},{})=", slot_index + 1)?;
            match slot {
                Slot::Live(row) => write!(w, "id {}", row.id)?,
                Slot::Dead => write!(w, "dead")?,
            }
        }
        writeln!(w)?;
    }
    Ok(())
}

fn describe(w: &mut dyn Write, t: &Table) -> io::Result<()> {
    match t.layout {
        Layout::Clustered => {
            writeln!(
                w,
                "\n-- clustered: the row is in the primary tree; locator = row id, printed #id --"
            )?;
            write!(w, "  primary tree (id -> row): ")?;
            dump::dump(&t.primary, w)?;
        }
        Layout::Heap => {
            writeln!(
                w,
                "\n-- heap + index: the row is in the heap; locator = TID, printed (page,slot) --"
            )?;
            print_heap(w, t)?;
            write!(w, "  primary key index (id,TID):")?;
            print_index(w, t.layout, &t.primary, KeyKind::Column)?;
        }
    }
    write!(w, "  by_customer_day (customer,day,locator):")?;
    print_index(w, t.layout, &t.by_customer_day, KeyKind::CustomerDay)?;
    write!(w, "  by_code (code,locator):")?;
    print_index(w, t.layout, &t.by_code, KeyKind::Column)
}

/// The same queries on 2000 seeded random rows and wider nodes; prints only
/// counts. Both layouts must return the same rows.
fn scale_run(w: &mut dyn Write, rows: &mut Vec<Row>, keys: &mut Vec<u64>) -> io::Result<()> {
    const ROW_TARGET: usize = 2000;
    writeln!(
        w,
        "\n== 8. The same queries on 2000 random rows, order M = 16 =="
    )?;
    let mut tables = [
        Table::new(Layout::Clustered, 16),
        Table::new(Layout::Heap, 16),
    ];
    let mut ids: Vec<u32> = Vec::new();

    let mut rng = SplitMix64::new(18);
    let mut attempts: u64 = 0;
    while ids.len() < ROW_TARGET {
        let row = Row {
            id: rng.below(100_000) as u32,
            customer: rng.below(50) as u16,
            day: rng.below(365) as u16,
            amount: rng.below(1000) as u16,
            // 7919 is odd, so i -> i * 7919 mod 65536 never repeats: codes are unique.
            code: (attempts * 7919 % 65536) as u16,
        };
        let mut accepted = [false; 2];
        for (t, ok) in tables.iter_mut().zip(&mut accepted) {
            *ok = match t.insert(row) {
                Ok(()) => true,
                Err(InsertError::DuplicatePrimaryKey) => false,
                Err(other) => panic!("unexpected {other:?}"),
            };
        }
        assert_eq!(accepted[0], accepted[1]);
        if accepted[0] {
            ids.push(row.id);
        }
        attempts += 1;
    }
    writeln!(
        w,
        "{} rows loaded, {} inserts rejected for a duplicate id",
        ids.len(),
        attempts - ROW_TARGET as u64
    )?;
    for t in &tables {
        t.validate().expect("valid table");
        writeln!(
            w,
            "{}: primary height {} ({} nodes), by_customer_day height {} ({} nodes), by_code height {} ({} nodes), heap pages {}",
            name(t.layout),
            t.primary.height,
            t.primary.nodes.live_count(),
            t.by_customer_day.height,
            t.by_customer_day.nodes.live_count(),
            t.by_code.height,
            t.by_code.nodes.live_count(),
            t.heap.page_count()
        )?;
    }

    writeln!(
        w,
        "\nlayout     query                                rows  descents  tree nodes  row fetches  heap reads  page reads"
    )?;
    for t in &tables {
        print_line(w, t.layout, "2000 inserts", ROW_TARGET, t.counters.get())?;
    }

    // Each workload runs on both layouts; `checksum` proves they agree.
    let mut checksum = [0u64; 2];
    let mut returned = [0usize; 2];

    for (i, t) in tables.iter().enumerate() {
        let before = t.counters.get();
        for &id in &ids {
            let row = t.get_by_id(id).expect("inserted id");
            checksum[i] = checksum[i].wrapping_add(u64::from(row.amount));
        }
        let cost = t.counters.get().minus(before);
        print_line(w, t.layout, "2000 x WHERE id = ?", ids.len(), cost)?;
    }
    for (i, t) in tables.iter().enumerate() {
        let before = t.counters.get();
        returned[i] = 0;
        for customer in 0..50 {
            t.fetch_scan(rows, row::customer_range(customer));
            for row in rows.iter() {
                checksum[i] = checksum[i].wrapping_add(u64::from(row.id) * u64::from(row.amount));
            }
            returned[i] += rows.len();
        }
        let cost = t.counters.get().minus(before);
        print_line(
            w,
            t.layout,
            "50 x SELECT * WHERE customer = ?",
            returned[i],
            cost,
        )?;
    }
    for (i, t) in tables.iter().enumerate() {
        let before = t.counters.get();
        returned[i] = 0;
        for customer in 0..50 {
            t.index_only_scan(keys, row::customer_range(customer));
            for &key in keys.iter() {
                checksum[i] = checksum[i].wrapping_add(u64::from(row::key_day(key)));
            }
            returned[i] += keys.len();
        }
        let cost = t.counters.get().minus(before);
        print_line(
            w,
            t.layout,
            "50 x SELECT day WHERE customer = ?",
            returned[i],
            cost,
        )?;
    }
    for (i, t) in tables.iter().enumerate() {
        let before = t.counters.get();
        returned[i] = 0;
        for customer in 0..50 {
            let range: KeyRange = row::customer_days_range(customer, 100, 129);
            t.fetch_scan(rows, range);
            for row in rows.iter() {
                checksum[i] = checksum[i].wrapping_add(u64::from(row.id) * u64::from(row.day));
            }
            returned[i] += rows.len();
        }
        let cost = t.counters.get().minus(before);
        print_line(
            w,
            t.layout,
            "50 x ... AND day BETWEEN 100 AND 129",
            returned[i],
            cost,
        )?;
    }
    for (i, t) in tables.iter().enumerate() {
        let before = t.counters.get();
        returned[i] = t.count_on_day(180);
        checksum[i] = checksum[i].wrapping_add(returned[i] as u64);
        let cost = t.counters.get().minus(before);
        print_line(
            w,
            t.layout,
            "1 x SELECT count(*) WHERE day = 180",
            returned[i],
            cost,
        )?;
    }
    for (i, t) in tables.iter_mut().enumerate() {
        let before = t.counters.get();
        returned[i] = 0;
        for &id in ids.iter().step_by(4) {
            returned[i] += usize::from(t.delete(id));
        }
        let cost = t.counters.get().minus(before);
        print_line(w, t.layout, "500 x DELETE WHERE id = ?", returned[i], cost)?;
        t.validate().expect("valid table");
    }
    writeln!(
        w,
        "\nboth layouts returned the same rows: {}; rows left: {} and {}; dead heap slots: {}",
        checksum[0] == checksum[1] && returned[0] == returned[1],
        tables[0].rows,
        tables[1].rows,
        tables[1].heap.page_count() * SLOTS_PER_PAGE - tables[1].heap.live_rows
    )
}

fn print_line(
    w: &mut dyn Write,
    layout: Layout,
    query: &str,
    rows: usize,
    c: Counters,
) -> io::Result<()> {
    writeln!(
        w,
        "{}  {query:<36} {rows:>4}  {:>8}  {:>10}  {:>11}  {:>10}  {:>10}",
        name(layout),
        c.descents,
        c.tree_nodes,
        c.row_fetches,
        c.heap_reads,
        c.page_reads()
    )
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
