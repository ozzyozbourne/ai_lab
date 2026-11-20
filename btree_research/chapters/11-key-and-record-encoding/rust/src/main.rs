//! Chapter 11: key and record encoding. `cargo run` prints the fixed
//! scenario that the README quotes and the visualization embeds.
//!
//! Memory idioms on show (see README "Allocator notes"):
//!   Bump       all eight sort keys of section 5 live in one fixed-capacity
//!              `Vec<u8>` and are referred to by offset ranges
//!   RowArena   a row decoded from a key (section 6) and the model test
//!   SmallBuf   one key at a time: inline first, heap on overflow
use std::cmp::Ordering;
use std::io::{self, Write};

#[allow(dead_code)] // small library: `reset` is only exercised by its tests
mod bump;
#[allow(dead_code)] // standalone library file: this program uses part of its API
mod keycodec;
mod model;
#[allow(dead_code)] // copied from common/: only part of its API is used here
mod prng;
mod record;
mod row;
#[allow(dead_code)] // standalone library file: this program uses part of its API
mod varint;

use bump::Bump;
use keycodec::{ColumnOpts, KeyWriter};
use prng::SplitMix64;
use row::{Column, ColumnType, RowArena, Value};

fn main() -> io::Result<()> {
    let mut out = io::BufWriter::new(io::stdout().lock());
    run(&mut out)?;
    out.flush()
}

// ---- small printing helpers -------------------------------------------------

/// Formats bytes as "61 00 ff".
fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect::<Vec<_>>().join(" ")
}

/// Formats a byte string as a quoted literal, non-printable bytes as \xNN.
fn quoted(s: &[u8]) -> String {
    let mut out = String::from("\"");
    for &c in s {
        if (0x20..=0x7e).contains(&c) {
            out.push(c as char);
        } else {
            out.push_str(&format!("\\x{c:02x}"));
        }
    }
    out.push('"');
    out
}

fn value_text(v: Value<'_>) -> String {
    match v {
        Value::Null => "NULL".to_string(),
        Value::Int(x) => x.to_string(),
        Value::Float(x) => format!("f64:0x{:016x}", x.to_bits()),
        Value::Text(s) => quoted(s),
    }
}

fn row_text(row: &[Value<'_>]) -> String {
    format!("({})", row.iter().map(|&v| value_text(v)).collect::<Vec<_>>().join(", "))
}

/// Insertion sort of an index array; `compare(i, j)` orders two items.
/// Hand-written so that Zig and Rust perform exactly the same comparisons
/// and the printed counts match (library sorts differ between languages).
fn insertion_sort(order: &mut [usize], mut compare: impl FnMut(usize, usize) -> Ordering) {
    for i in 1..order.len() {
        let mut j = i;
        while j > 0 && compare(order[j - 1], order[j]) == Ordering::Greater {
            order.swap(j - 1, j);
            j -= 1;
        }
    }
}

/// memcmp that counts how many byte positions it looked at.
fn compare_bytes_counted(a: &[u8], b: &[u8], examined: &mut u64) -> Ordering {
    for (x, y) in a.iter().zip(b) {
        *examined += 1;
        if x != y {
            return x.cmp(y);
        }
    }
    a.len().cmp(&b.len())
}

// ---- the fixed scenario -------------------------------------------------------

/// (name ASC, score DESC NULLS LAST, id ASC)
const PEOPLE_SCHEMA: [Column; 3] = [
    Column {
        ty: ColumnType::Text,
        opts: ColumnOpts::ASC,
    },
    Column {
        ty: ColumnType::Int,
        opts: ColumnOpts::DESC,
    },
    Column {
        ty: ColumnType::Int,
        opts: ColumnOpts::ASC,
    },
];

const PEOPLE: [[Value<'static>; 3]; 8] = [
    [Value::Text(b"Anna"), Value::Int(7), Value::Int(1)],
    [Value::Text(b"Ann"), Value::Int(7), Value::Int(2)],
    [Value::Text(b"Ann"), Value::Int(-2), Value::Int(3)],
    [Value::Text(b"Ann"), Value::Null, Value::Int(4)],
    [Value::Text(b"Bo"), Value::Int(300), Value::Int(5)],
    [Value::Text(b"Bo"), Value::Int(300), Value::Int(6)],
    [Value::Text(b""), Value::Int(0), Value::Int(7)],
    [Value::Text(b"Anna"), Value::Int(256), Value::Int(8)],
];

/// The id column of a people row.
fn id_of(row: &[Value<'_>; 3]) -> i64 {
    match row[2] {
        Value::Int(id) => id,
        _ => unreachable!("id is never NULL"),
    }
}

fn run(w: &mut impl Write) -> io::Result<()> {
    section_varints(w)?;
    section_integers(w)?;
    section_floats(w)?;
    section_strings(w)?;
    section_composite(w)?;
    section_record(w)?;
    section_allocators(w)?;
    section_property(w)
}

fn section_varints(w: &mut impl Write) -> io::Result<()> {
    writeln!(w, "== 1. varints: small numbers, few bytes ==")?;
    writeln!(w, "{:<21}{:<31}sqlite", "value", "leb128")?;
    let leb = |v: u64| {
        let mut buf = [0u8; varint::MAX_LEN];
        let n = varint::encode(&mut buf, v).expect("MAX_LEN bytes always fit");
        buf[..n].to_vec()
    };
    for v in [0, 1, 127, 128, 300, 16383, 16384, 1 << 32, u64::MAX] {
        let mut b = [0u8; varint::SQLITE_MAX_LEN];
        let nb = varint::sqlite_encode(&mut b, v).expect("SQLITE_MAX_LEN bytes always fit");
        writeln!(w, "{:<21}{:<31}{}", v, hex(&leb(v)), hex(&b[..nb]))?;
    }
    write!(w, "zigzag:")?;
    for v in [0i64, -1, 1, -2, 2, -64, 64] {
        write!(w, " {}->{}", v, varint::zigzag(v))?;
    }
    writeln!(w)?;
    let (a, c) = (leb(129), leb(256));
    writeln!(
        w,
        "as bytes: leb128(129) = {} {} leb128(256) = {}, but 129 < 256: varints are not sort keys\n",
        hex(&a),
        if a > c { ">" } else { "<=" },
        hex(&c)
    )
}

fn section_integers(w: &mut impl Write) -> io::Result<()> {
    writeln!(w, "== 2. integers as keys ==")?;
    let values: [i64; 5] = [-2, -1, 0, 1, 256];
    writeln!(w, "i64 values -2 -1 0 1 256, sorted by comparing the bytes of each encoding:")?;
    type Encoder = fn(i64) -> [u8; 8];
    let encodings: [(&str, Encoder); 3] = [
        ("little-endian", i64::to_le_bytes),
        ("big-endian", i64::to_be_bytes),
        ("big-endian + sign flip", keycodec::encode_i64),
    ];
    for (label, encode) in encodings {
        let enc = values.map(encode);
        let mut order = [0, 1, 2, 3, 4];
        insertion_sort(&mut order, |i, j| enc[i].cmp(&enc[j]));
        write!(w, "  {label:<23}:")?;
        for &idx in &order {
            write!(w, " {}", values[idx])?;
        }
        let sorted = order.iter().enumerate().all(|(pos, &idx)| pos == idx);
        writeln!(w, "  {}", if sorted { "(correct)" } else { "(WRONG)" })?;
    }
    for v in values {
        writeln!(w, "  {:>4} -> {}", v, hex(&keycodec::encode_i64(v)))?;
    }
    writeln!(w)
}

fn section_floats(w: &mut impl Write) -> io::Result<()> {
    writeln!(w, "== 3. floats as keys ==")?;
    let values = [
        (f64::NEG_INFINITY, "-inf"),
        (-1.5, "-1.5"),
        (-0.0, "-0.0"),
        (0.0, "0.0"),
        (1.5, "1.5"),
        (f64::INFINITY, "+inf"),
        (f64::NAN, "NaN"),
    ];
    let mut prev: Option<[u8; 8]> = None;
    for (v, label) in values {
        let e = keycodec::encode_f64(v);
        // Relation to the previous line: the list is in logical order, so
        // every key must be >= the one before it.
        let rel = match prev.map(|p| p.cmp(&e)) {
            None => "",
            Some(Ordering::Less) => "  (> previous)",
            Some(Ordering::Equal) => "  (= previous)",
            Some(Ordering::Greater) => "  (< previous: BUG)",
        };
        writeln!(w, "  {:>4} -> {}{}", label, hex(&e), rel)?;
        prev = Some(e);
    }
    writeln!(w)
}

fn section_strings(w: &mut impl Write) -> io::Result<()> {
    writeln!(w, "== 4. strings as keys ==")?;
    let values: [&[u8]; 7] = [b"", b"a", b"a\x00", b"a\x01", b"a\x02", b"ab", b"b"];
    for s in values {
        let mut e = [0u8; 16];
        let n = keycodec::encode_bytes(&mut e, s).expect("16 bytes are enough");
        writeln!(w, "  {:<8} -> {}", quoted(s), hex(&e[..n]))?;
    }
    // Why the terminator exists: two different composite values.
    let pair = |first: &[u8], second: &[u8]| {
        let mut buf = [0u8; 16];
        let mut k = KeyWriter::new(&mut buf);
        k.put_bytes(first, ColumnOpts::ASC).expect("fits");
        k.put_bytes(second, ColumnOpts::ASC).expect("fits");
        hex(k.written())
    };
    writeln!(w, "  raw concatenation: (\"a\",\"b\") and (\"ab\",\"\") are both 61 62")?;
    writeln!(
        w,
        "  as key columns   : (\"a\",\"b\") = {}   (\"ab\",\"\") = {}\n",
        pair(b"a", b"b"),
        pair(b"ab", b"")
    )
}

fn section_composite(w: &mut impl Write) -> io::Result<()> {
    writeln!(w, "== 5. composite keys: (name ASC, score DESC NULLS LAST, id ASC) ==")?;

    // Arrival order of the rows: a seeded shuffle of 0..7.
    let mut shuffled: [u64; 8] = [0, 1, 2, 3, 4, 5, 6, 7];
    SplitMix64::new(11).shuffle(&mut shuffled);
    let arrived: Vec<&[Value<'_>; 3]> = shuffled.iter().map(|&i| &PEOPLE[i as usize]).collect();
    write!(w, "arrival order (ids):")?;
    for row in &arrived {
        write!(w, " {}", id_of(row))?;
    }
    writeln!(w)?;

    // All keys and all records are bump-allocated from two fixed-size buffers.
    let mut key_bump = Bump::with_limit(256);
    let mut rec_bump = Bump::with_limit(128);
    let mut key_ranges = Vec::new();
    let mut rec_ranges = Vec::new();
    for row in &arrived {
        key_ranges.push(row::encode_key_bump(&mut key_bump, *row, &PEOPLE_SCHEMA).expect("256 bytes are enough"));
        let range = rec_bump.alloc(record::record_len(*row)).expect("128 bytes are enough");
        record::encode_record(rec_bump.get_mut(range.clone()), *row).expect("sized by record_len");
        rec_ranges.push(range);
    }
    let keys: Vec<&[u8]> = key_ranges.iter().map(|r| key_bump.get(r.clone())).collect();
    let recs: Vec<&[u8]> = rec_ranges.iter().map(|r| rec_bump.get(r.clone())).collect();

    // (a) sort by comparing key bytes; the sort knows nothing about columns.
    let mut by_bytes = [0, 1, 2, 3, 4, 5, 6, 7];
    let (mut comparisons, mut bytes_examined) = (0u64, 0u64);
    insertion_sort(&mut by_bytes, |i, j| {
        comparisons += 1;
        compare_bytes_counted(keys[i], keys[j], &mut bytes_examined)
    });

    // (b) sort the records with the schema-aware comparator.
    let mut by_comparator = [0, 1, 2, 3, 4, 5, 6, 7];
    let mut stats = record::CompareStats::default();
    insertion_sort(&mut by_comparator, |i, j| {
        record::compare_records(recs[i], recs[j], &PEOPLE_SCHEMA, Some(&mut stats)).expect("records we just encoded")
    });

    writeln!(
        w,
        "sorted by key bytes ({comparisons} comparisons, {bytes_examined} byte positions examined):"
    )?;
    for &i in &by_bytes {
        let row = arrived[i];
        let Value::Text(name) = row[0] else {
            unreachable!("name is never NULL")
        };
        let score = match row[1] {
            Value::Int(x) => x.to_string(),
            _ => "NULL".to_string(),
        };
        writeln!(w, "  id {}  {:<6} {:>4}  {}", id_of(row), quoted(name), score, hex(keys[i]))?;
    }
    writeln!(
        w,
        "sorted by record comparator ({} comparisons, {} columns decoded):",
        stats.calls, stats.columns_decoded
    )?;
    write!(w, " ")?;
    for &i in &by_comparator {
        write!(w, " {}", id_of(arrived[i]))?;
    }
    writeln!(w, "\nsame order: {}", if by_bytes == by_comparator { "yes" } else { "NO" })?;
    writeln!(
        w,
        "space: 8 keys = {} bytes of a {}-byte fixed buffer, 8 records = {} bytes\n",
        key_bump.used(),
        key_bump.limit(),
        rec_bump.used()
    )
}

fn section_record(w: &mut impl Write) -> io::Result<()> {
    writeln!(w, "== 6. one row, two encodings ==")?;
    let row = &PEOPLE[0];
    let mut rec_buf = [0u8; 32];
    let mut key_buf = [0u8; 32];
    let rec = record::encode_record(&mut rec_buf, row).expect("32 bytes are enough");
    let key = row::encode_key(&mut key_buf, row, &PEOPLE_SCHEMA).expect("32 bytes are enough");
    writeln!(w, "row    {}", row_text(row))?;
    writeln!(w, "record {}  ({} bytes)", hex(rec), rec.len())?;
    writeln!(w, "key    {}  ({} bytes)", hex(key), key.len())?;

    // The record's text is borrowed straight from `rec`; the key's text has
    // to be un-escaped into the arena's bump buffer.
    let from_rec = record::decode_record(rec).expect("record we just encoded");
    let mut arena = RowArena::new();
    row::decode_key(&mut arena, key, &PEOPLE_SCHEMA).expect("key we just encoded");
    writeln!(w, "record -> {}   (self-describing)", row_text(&from_rec))?;
    writeln!(w, "key    -> {}   (needs the schema)\n", row_text(&arena.values()))
}

fn section_allocators(w: &mut impl Write) -> io::Result<()> {
    writeln!(w, "== 7. where the key bytes live ==")?;
    let rows = [PEOPLE[4], [Value::Text(b"Bartholomew-Maximilian"), Value::Null, Value::Int(9)]];
    for row in &rows {
        // Up to 32 bytes inline in the SmallBuf value; the heap is only the fallback.
        let key = row::encode_key_small::<32>(row, &PEOPLE_SCHEMA).expect("types match the schema");
        let Value::Text(name) = row[0] else {
            unreachable!("name is never NULL")
        };
        writeln!(
            w,
            "  key for {:<24} {:>2} bytes -> {}",
            quoted(name),
            key.as_slice().len(),
            if key.is_inline() { "32-byte stack buffer" } else { "heap fallback" }
        )?;
    }
    writeln!(w)
}

fn section_property(w: &mut impl Write) -> io::Result<()> {
    writeln!(w, "== 8. the property, checked on random rows ==")?;
    let (seed, pairs) = (11, 2000);
    match model::check_pairs(seed, pairs) {
        Ok(c) => {
            writeln!(w, "seed {seed}, {pairs} pairs: {} less, {} equal, {} greater", c.lt, c.eq, c.gt)?;
            writeln!(w, "byte order of keys == comparator order of records == logical order: yes")
        }
        Err(model::Mismatch) => writeln!(w, "MISMATCH"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn run_prints_exactly_expected_output_txt() {
        let mut out = Vec::new();
        run(&mut out).unwrap();
        assert_eq!(String::from_utf8(out).unwrap(), include_str!("../../expected_output.txt"));
    }

    #[test]
    fn the_people_table_sorts_as_the_readme_says() {
        // Logical order by id: 7, 2, 3, 4, 8, 1, 5, 6.
        let mut order = [0, 1, 2, 3, 4, 5, 6, 7];
        insertion_sort(&mut order, |i, j| row::compare_rows(&PEOPLE[i], &PEOPLE[j], &PEOPLE_SCHEMA));
        assert_eq!(order.map(|i| id_of(&PEOPLE[i])), [7, 2, 3, 4, 8, 1, 5, 6]);
    }
}
