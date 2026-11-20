//! Typed rows: the logical layer above the two encodings.
//!
//! `compare_rows` is the definition of "logical order" for this chapter and
//! the ORACLE of the model test: it looks only at values, never at bytes.
//! `encode_key` maps a row to a byte-comparable key (keycodec.rs); record.rs
//! maps a row to a compact record that needs a comparator.
use std::cmp::Ordering;
use std::ops::Range;

use crate::bump::{Bump, OutOfSpace, SmallBuf};
use crate::keycodec::{self, ColumnOpts, KeyError, KeyReader, KeyWriter};

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Value<'a> {
    Null,
    Int(i64),
    Float(f64),
    /// Borrowed bytes; compared bytewise (no collation).
    Text(&'a [u8]),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ColumnType {
    Int,
    Float,
    Text,
}

/// One key column: its type and how it sorts. A slice of these is the schema
/// that both the comparator and the key decoder need; the bytes do not carry it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Column {
    pub ty: ColumnType,
    pub opts: ColumnOpts,
}

/// Float order used everywhere in this chapter: -0 equals +0, all NaNs are
/// equal to each other and greater than every number.
pub fn order_f64(a: f64, b: f64) -> Ordering {
    // partial_cmp is None exactly when a NaN is involved.
    a.partial_cmp(&b).unwrap_or_else(|| a.is_nan().cmp(&b.is_nan()))
}

/// Logical order of two values of the same column.
/// The NULL rules are those of Postgres' `_bt_compare`: NULL equals NULL,
/// NULLS FIRST / LAST decides NULL against a value, and DESC reverses only
/// value-against-value comparisons.
pub fn compare_values(a: Value<'_>, b: Value<'_>, opts: ColumnOpts) -> Ordering {
    let null_vs_value = if opts.nulls_first { Ordering::Less } else { Ordering::Greater };
    let asc = match (a, b) {
        (Value::Null, Value::Null) => return Ordering::Equal,
        (Value::Null, _) => return null_vs_value,
        (_, Value::Null) => return null_vs_value.reverse(),
        (Value::Int(x), Value::Int(y)) => x.cmp(&y),
        (Value::Float(x), Value::Float(y)) => order_f64(x, y),
        (Value::Text(x), Value::Text(y)) => x.cmp(y),
        _ => unreachable!("both values belong to the same typed column"),
    };
    if opts.desc { asc.reverse() } else { asc }
}

/// Lexicographic over the columns: the first column that differs decides.
pub fn compare_rows(a: &[Value<'_>], b: &[Value<'_>], schema: &[Column]) -> Ordering {
    for (col, (&x, &y)) in schema.iter().zip(a.iter().zip(b)) {
        let o = compare_values(x, y, col.opts);
        if o != Ordering::Equal {
            return o;
        }
    }
    Ordering::Equal
}

pub fn matches(v: Value<'_>, t: ColumnType) -> bool {
    match v {
        Value::Null => true,
        Value::Int(_) => t == ColumnType::Int,
        Value::Float(_) => t == ColumnType::Float,
        Value::Text(_) => t == ColumnType::Text,
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RowError {
    /// A value whose type is not the column's type.
    TypeMismatch,
    /// The key continues after its last column.
    TrailingBytes,
    /// A float column holding bits that `encode_f64` never produces.
    NotCanonical,
    /// The bump allocator is full.
    OutOfSpace,
    Key(KeyError),
}

impl From<KeyError> for RowError {
    fn from(e: KeyError) -> Self {
        RowError::Key(e)
    }
}

impl From<OutOfSpace> for RowError {
    fn from(_: OutOfSpace) -> Self {
        RowError::OutOfSpace
    }
}

/// Exact number of bytes `encode_key` produces for `row`.
pub fn key_len(row: &[Value<'_>]) -> usize {
    row.iter()
        .map(|v| match v {
            Value::Null => 1,
            Value::Int(_) | Value::Float(_) => 9,
            Value::Text(s) => 1 + keycodec::encoded_bytes_len(s),
        })
        .sum()
}

/// Encodes `row` as one composite key into `buf` and returns the used part.
/// Contract: `row.len() == schema.len()`. It is asserted, not returned as an
/// error, because the row comes from the caller, not from disk.
pub fn encode_key<'b>(buf: &'b mut [u8], row: &[Value<'_>], schema: &[Column]) -> Result<&'b [u8], RowError> {
    assert_eq!(row.len(), schema.len());
    let mut w = KeyWriter::new(&mut *buf);
    for (col, &v) in schema.iter().zip(row) {
        if !matches(v, col.ty) {
            return Err(RowError::TypeMismatch);
        }
        match v {
            Value::Null => w.put_null(col.opts)?,
            Value::Int(x) => w.put_i64(x, col.opts)?,
            Value::Float(x) => w.put_f64(x, col.opts)?,
            Value::Text(x) => w.put_bytes(x, col.opts)?,
        }
    }
    let n = w.len();
    Ok(&buf[..n])
}

/// Same, into exactly `key_len(row)` bytes claimed from `bump`; returns where
/// the key lives. On error the bump is left as it was.
pub fn encode_key_bump(bump: &mut Bump, row: &[Value<'_>], schema: &[Column]) -> Result<Range<usize>, RowError> {
    // Check the types first so that a failed call claims nothing.
    if schema.iter().zip(row).any(|(col, &v)| !matches(v, col.ty)) {
        return Err(RowError::TypeMismatch);
    }
    let range = bump.alloc(key_len(row))?;
    let n = encode_key(bump.get_mut(range.clone()), row, schema)?.len();
    debug_assert_eq!(n, range.len());
    Ok(range)
}

/// Same, into a `SmallBuf`: keys of up to N bytes never touch the heap.
pub fn encode_key_small<const N: usize>(row: &[Value<'_>], schema: &[Column]) -> Result<SmallBuf<N>, RowError> {
    let mut buf = SmallBuf::<N>::with_len(key_len(row));
    encode_key(buf.as_mut_slice(), row, schema)?;
    Ok(buf)
}

/// Storage for one decoded row: all text bytes in one bump `Vec<u8>`, the
/// columns referring to them by offset range. `clear` keeps the capacity, so
/// one arena reused across many rows stops allocating (the counterpart of
/// Zig's `arena.reset(.retain_capacity)`).
#[derive(Debug, Default)]
pub struct RowArena {
    text: Vec<u8>,
    cols: Vec<ArenaCol>,
}

#[derive(Debug)]
enum ArenaCol {
    Null,
    Int(i64),
    Float(f64),
    Text(Range<usize>),
}

impl RowArena {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn clear(&mut self) {
        self.text.clear();
        self.cols.clear();
    }

    /// The decoded row as borrowed values.
    pub fn values(&self) -> Vec<Value<'_>> {
        self.cols
            .iter()
            .map(|c| match c {
                ArenaCol::Null => Value::Null,
                ArenaCol::Int(x) => Value::Int(*x),
                ArenaCol::Float(x) => Value::Float(*x),
                ArenaCol::Text(r) => Value::Text(&self.text[r.clone()]),
            })
            .collect()
    }
}

/// Decodes a key back into values stored in `arena` (which is cleared first).
/// Text cannot be borrowed from `key` the way record text can: it is stored
/// escaped (and inverted for DESC), so it has to be rebuilt somewhere.
pub fn decode_key(arena: &mut RowArena, key: &[u8], schema: &[Column]) -> Result<(), RowError> {
    arena.clear();
    let mut r = KeyReader::new(key);
    for col in schema {
        let decoded = match col.ty {
            ColumnType::Int => r.take_i64(col.opts)?.map_or(ArenaCol::Null, ArenaCol::Int),
            ColumnType::Float => r.take_f64(col.opts)?.map_or(ArenaCol::Null, ArenaCol::Float),
            ColumnType::Text => match r.bytes_len(col.opts)? {
                None => {
                    r.skip_bytes(col.opts)?; // consume the NULL tag
                    ArenaCol::Null
                }
                Some(n) => {
                    let start = arena.text.len();
                    arena.text.resize(start + n, 0);
                    r.take_bytes(&mut arena.text[start..], col.opts)?;
                    ArenaCol::Text(start..start + n)
                }
            },
        };
        arena.cols.push(decoded);
    }
    if !r.done() {
        return Err(RowError::TrailingBytes);
    }
    Ok(())
}

/// Checks that `key` is a well-formed key for `schema`, without allocating:
/// every column decodes, nothing is left over, and re-encoding each float
/// column gives the same bytes (so -0.0 or a stray NaN payload is caught).
pub fn validate_key(key: &[u8], schema: &[Column]) -> Result<(), RowError> {
    let mut r = KeyReader::new(key);
    for col in schema {
        let start = r.position();
        match col.ty {
            ColumnType::Int => {
                r.take_i64(col.opts)?;
            }
            ColumnType::Float => {
                if let Some(x) = r.take_f64(col.opts)? {
                    let mut expect = keycodec::encode_f64(x);
                    if col.opts.desc {
                        keycodec::invert(&mut expect);
                    }
                    if expect != key[start + 1..r.position()] {
                        return Err(RowError::NotCanonical);
                    }
                }
            }
            ColumnType::Text => {
                r.skip_bytes(col.opts)?;
            }
        }
    }
    if !r.done() {
        return Err(RowError::TrailingBytes);
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use Value::{Int, Null, Text};

    const PEOPLE: [Column; 3] = [
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

    #[test]
    fn compare_values_null_rules_and_desc() {
        let asc = ColumnOpts::ASC;
        let desc = ColumnOpts::DESC;
        assert_eq!(compare_values(Int(1), Int(2), asc), Ordering::Less);
        assert_eq!(compare_values(Int(1), Int(2), desc), Ordering::Greater);
        assert_eq!(compare_values(Null, Null, desc), Ordering::Equal);
        // NULL placement ignores DESC.
        assert_eq!(compare_values(Null, Int(1), asc), Ordering::Greater);
        assert_eq!(compare_values(Null, Int(1), desc), Ordering::Greater);
        assert_eq!(
            compare_values(
                Null,
                Int(1),
                ColumnOpts {
                    desc: false,
                    nulls_first: true
                }
            ),
            Ordering::Less
        );
        assert_eq!(
            compare_values(
                Null,
                Int(1),
                ColumnOpts {
                    desc: true,
                    nulls_first: true
                }
            ),
            Ordering::Less
        );
        // Floats: NaN is the greatest, zeros are equal.
        assert_eq!(order_f64(-0.0, 0.0), Ordering::Equal);
        assert_eq!(order_f64(f64::NAN, f64::INFINITY), Ordering::Greater);
        assert_eq!(order_f64(f64::NAN, f64::NAN), Ordering::Equal);
    }

    #[test]
    fn encode_key_key_order_equals_row_order_and_decode_key_round_trips() {
        let rows: [[Value; 3]; 4] = [
            [Text(b"Ann"), Int(7), Int(2)],
            [Text(b"Ann"), Int(-2), Int(3)],
            [Text(b"Ann"), Null, Int(4)],
            [Text(b"Anna"), Int(256), Int(8)],
        ]; // in logical order

        let mut arena = RowArena::new();
        let mut keys: Vec<Vec<u8>> = Vec::new();
        for row in &rows {
            let mut buf = [0u8; 64];
            let key = encode_key(&mut buf, row, &PEOPLE).unwrap();
            assert_eq!(key.len(), key_len(row));
            validate_key(key, &PEOPLE).unwrap();
            decode_key(&mut arena, key, &PEOPLE).unwrap();
            assert_eq!(compare_rows(row, &arena.values(), &PEOPLE), Ordering::Equal);
            keys.push(key.to_vec());
        }
        for i in 0..rows.len() {
            for j in 0..rows.len() {
                assert_eq!(keys[i].cmp(&keys[j]), compare_rows(&rows[i], &rows[j], &PEOPLE));
            }
        }
    }

    #[test]
    fn encode_key_errors_wrong_type_no_space() {
        let mut buf = [0u8; 64];
        let wrong = [Int(1), Int(1), Int(1)];
        assert_eq!(encode_key(&mut buf, &wrong, &PEOPLE), Err(RowError::TypeMismatch));
        let row = [Text(b"Ann"), Int(7), Int(2)];
        let short = key_len(&row) - 1;
        assert_eq!(
            encode_key(&mut buf[..short], &row, &PEOPLE),
            Err(RowError::Key(KeyError::NoSpaceLeft))
        );
    }

    #[test]
    fn validate_key_and_decode_key_reject_malformed_keys() {
        let mut buf = [0u8; 64];
        let row = [Text(b"Ann"), Int(7), Int(2)];
        let n = encode_key(&mut buf, &row, &PEOPLE).unwrap().len();
        // Cut anywhere (inside the text, after its terminator, on a tag, inside
        // an integer), the key is Truncated; decode_key agrees.
        for cut in 0..n {
            assert_eq!(validate_key(&buf[..cut], &PEOPLE), Err(RowError::Key(KeyError::Truncated)));
            assert_eq!(
                decode_key(&mut RowArena::new(), &buf[..cut], &PEOPLE),
                Err(RowError::Key(KeyError::Truncated))
            );
        }
        buf[n] = 0;
        assert_eq!(validate_key(&buf[..n + 1], &PEOPLE), Err(RowError::TrailingBytes));
        assert_eq!(
            decode_key(&mut RowArena::new(), &buf[..n + 1], &PEOPLE),
            Err(RowError::TrailingBytes)
        );

        // A float column holding the bit pattern of -0.0 (never produced by encode_f64).
        let floats = [Column {
            ty: ColumnType::Float,
            opts: ColumnOpts::ASC,
        }];
        let minus_zero = [keycodec::TAG_VALUE, 0x7f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff];
        assert_eq!(validate_key(&minus_zero, &floats), Err(RowError::NotCanonical));
    }

    #[test]
    fn allocation_failure_encode_key_bump_claims_nothing_when_full() {
        let row = [Text(b"a name long enough to matter"), Null, Int(2)];
        let need = key_len(&row);
        // Every budget below `need` must fail and leave the bump untouched.
        for limit in 0..need {
            let mut bump = Bump::with_limit(limit);
            assert_eq!(encode_key_bump(&mut bump, &row, &PEOPLE), Err(RowError::OutOfSpace));
            assert_eq!(bump.used(), 0);
        }
        let mut bump = Bump::with_limit(need);
        let range = encode_key_bump(&mut bump, &row, &PEOPLE).unwrap();
        validate_key(bump.get(range), &PEOPLE).unwrap();
        // A type error is detected before any space is claimed.
        let mut bump = Bump::with_limit(64);
        assert_eq!(
            encode_key_bump(&mut bump, &[Int(1), Int(1), Int(1)], &PEOPLE),
            Err(RowError::TypeMismatch)
        );
        assert_eq!(bump.used(), 0);
    }

    #[test]
    fn small_buf_short_keys_inline_long_keys_on_the_heap() {
        let short = [Text(b"Bo"), Int(300), Int(5)];
        let k1 = encode_key_small::<32>(&short, &PEOPLE).unwrap();
        assert!(k1.is_inline());
        validate_key(k1.as_slice(), &PEOPLE).unwrap();

        let long = [Text(b"a name that does not fit in thirty-two bytes"), Int(300), Int(5)];
        let k2 = encode_key_small::<32>(&long, &PEOPLE).unwrap();
        assert!(!k2.is_inline());
        validate_key(k2.as_slice(), &PEOPLE).unwrap();
    }

    #[test]
    fn row_arena_reuse_keeps_capacity() {
        let mut arena = RowArena::new();
        let mut buf = [0u8; 64];
        let key = encode_key(&mut buf, &[Text(b"Anna"), Int(7), Int(1)], &PEOPLE).unwrap();
        decode_key(&mut arena, key, &PEOPLE).unwrap();
        let capacity = (arena.text.capacity(), arena.cols.capacity());
        decode_key(&mut arena, key, &PEOPLE).unwrap();
        assert_eq!((arena.text.capacity(), arena.cols.capacity()), capacity);
        assert_eq!(arena.values(), [Text(b"Anna"), Int(7), Int(1)]);
    }
}
