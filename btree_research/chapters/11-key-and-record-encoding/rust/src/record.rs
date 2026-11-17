//! Records: the compact, self-describing row format that needs a comparator.
//!
//! This is the SQLite / Turso record idea, simplified:
//!
//!     header_len   varint   number of bytes in the serial-type area
//!     serial types varint per column:
//!                    0      NULL            (no body bytes)
//!                    1      int             body: zigzag LEB128 varint
//!                    2      float           body: 8 bytes, little-endian IEEE bits
//!                    n >= 3 text of n - 3 bytes, stored raw
//!     bodies       in column order
//!
//! (Real SQLite: header_len includes itself, integers are fixed 1/2/3/4/6/8
//! bytes chosen by magnitude, and text is `13 + 2 * len`.)
//!
//! Compared with a key from keycodec.rs a record is smaller and can be read
//! back without a schema, but two records can only be ordered by decoding
//! their columns and calling a comparator (`compare_records`).
use std::cmp::Ordering;

use crate::row::{self, Column, Value};
use crate::varint::{self, VarintError};

const SERIAL_NULL: u64 = 0;
const SERIAL_INT: u64 = 1;
const SERIAL_FLOAT: u64 = 2;
const SERIAL_TEXT_BASE: u64 = 3;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RecordError {
    NoSpaceLeft,
    Truncated,
    Overflow,
    NonCanonical,
    /// Structurally wrong: trailing bytes, a missing column, a wrong type.
    Corrupt,
}

impl From<VarintError> for RecordError {
    fn from(e: VarintError) -> Self {
        match e {
            VarintError::NoSpaceLeft => RecordError::NoSpaceLeft,
            VarintError::Truncated => RecordError::Truncated,
            VarintError::Overflow => RecordError::Overflow,
            VarintError::NonCanonical => RecordError::NonCanonical,
        }
    }
}

fn serial_type(v: Value<'_>) -> u64 {
    match v {
        Value::Null => SERIAL_NULL,
        Value::Int(_) => SERIAL_INT,
        Value::Float(_) => SERIAL_FLOAT,
        Value::Text(s) => SERIAL_TEXT_BASE + s.len() as u64,
    }
}

fn header_len(row: &[Value<'_>]) -> usize {
    row.iter().map(|&v| varint::encoded_len(serial_type(v))).sum()
}

/// Exact number of bytes `encode_record` produces for `row`.
pub fn record_len(row: &[Value<'_>]) -> usize {
    let h = header_len(row);
    let bodies: usize = row
        .iter()
        .map(|v| match v {
            Value::Null => 0,
            Value::Int(x) => varint::encoded_len(varint::zigzag(*x)),
            Value::Float(_) => 8,
            Value::Text(s) => s.len(),
        })
        .sum();
    varint::encoded_len(h as u64) + h + bodies
}

/// Encodes `row` into `buf` and returns the used part.
pub fn encode_record<'b>(buf: &'b mut [u8], row: &[Value<'_>]) -> Result<&'b [u8], RecordError> {
    if buf.len() < record_len(row) {
        return Err(RecordError::NoSpaceLeft);
    }
    let mut pos = varint::encode(buf, header_len(row) as u64)?;
    for &v in row {
        pos += varint::encode(&mut buf[pos..], serial_type(v))?;
    }
    for &v in row {
        match v {
            Value::Null => {}
            Value::Int(x) => pos += varint::encode(&mut buf[pos..], varint::zigzag(x))?,
            Value::Float(x) => {
                buf[pos..pos + 8].copy_from_slice(&x.to_bits().to_le_bytes());
                pos += 8;
            }
            Value::Text(s) => {
                buf[pos..pos + s.len()].copy_from_slice(s);
                pos += s.len();
            }
        }
    }
    Ok(&buf[..pos])
}

/// Walks the columns of a record one at a time, without allocating.
/// Text values borrow from the record bytes.
#[derive(Debug, Clone)]
pub struct RecordCursor<'a> {
    bytes: &'a [u8],
    type_pos: usize,
    types_end: usize,
    body_pos: usize,
}

impl<'a> RecordCursor<'a> {
    pub fn new(bytes: &'a [u8]) -> Result<Self, RecordError> {
        let (h, h_len) = varint::decode(bytes)?;
        if h > (bytes.len() - h_len) as u64 {
            return Err(RecordError::Truncated);
        }
        let types_end = h_len + h as usize;
        Ok(Self {
            bytes,
            type_pos: h_len,
            types_end,
            body_pos: types_end,
        })
    }

    /// The next column, or None after the last one.
    pub fn next_column(&mut self) -> Result<Option<Value<'a>>, RecordError> {
        if self.type_pos == self.types_end {
            return Ok(None);
        }
        let (t, t_len) = varint::decode(&self.bytes[self.type_pos..self.types_end])?;
        let body = &self.bytes[self.body_pos..];
        let (value, used) = match t {
            SERIAL_NULL => (Value::Null, 0),
            SERIAL_INT => {
                let (z, n) = varint::decode(body)?;
                (Value::Int(varint::unzigzag(z)), n)
            }
            SERIAL_FLOAT => {
                let bits: [u8; 8] = body.get(..8).ok_or(RecordError::Truncated)?.try_into().expect("8 bytes");
                (Value::Float(f64::from_bits(u64::from_le_bytes(bits))), 8)
            }
            _ => {
                let n = t - SERIAL_TEXT_BASE;
                if n > body.len() as u64 {
                    return Err(RecordError::Truncated);
                }
                (Value::Text(&body[..n as usize]), n as usize)
            }
        };
        // Advance only after the whole column decoded.
        self.type_pos += t_len;
        self.body_pos += used;
        Ok(Some(value))
    }
}

/// Decodes a whole record. The text values BORROW from `bytes`: the lifetime
/// in the signature makes the compiler reject any use of the row after the
/// page buffer is modified or dropped, so no copy is needed. (The Zig version
/// copies the text into an arena because nothing would stop that misuse.)
pub fn decode_record(bytes: &[u8]) -> Result<Vec<Value<'_>>, RecordError> {
    let mut cursor = RecordCursor::new(bytes)?;
    let mut row = Vec::new();
    while let Some(v) = cursor.next_column()? {
        row.push(v);
    }
    if cursor.body_pos != bytes.len() {
        return Err(RecordError::Corrupt); // trailing bytes
    }
    Ok(row)
}

/// Structural check: header and bodies are consistent and nothing is left over.
pub fn validate_record(bytes: &[u8]) -> Result<(), RecordError> {
    let mut cursor = RecordCursor::new(bytes)?;
    while cursor.next_column()?.is_some() {}
    if cursor.body_pos != bytes.len() {
        return Err(RecordError::Corrupt);
    }
    Ok(())
}

/// Counters for the "what does a comparison cost" demonstration.
#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
pub struct CompareStats {
    pub calls: u64,
    pub columns_decoded: u64,
}

/// The comparator: orders two records by their first `schema.len()` columns.
/// It decodes column by column and stops at the first difference, so later
/// columns of long rows are never touched.
pub fn compare_records(a: &[u8], b: &[u8], schema: &[Column], mut stats: Option<&mut CompareStats>) -> Result<Ordering, RecordError> {
    if let Some(s) = stats.as_deref_mut() {
        s.calls += 1;
    }
    let mut ca = RecordCursor::new(a)?;
    let mut cb = RecordCursor::new(b)?;
    for col in schema {
        let va = ca.next_column()?.ok_or(RecordError::Corrupt)?;
        let vb = cb.next_column()?.ok_or(RecordError::Corrupt)?;
        if let Some(s) = stats.as_deref_mut() {
            s.columns_decoded += 2;
        }
        if !row::matches(va, col.ty) || !row::matches(vb, col.ty) {
            return Err(RecordError::Corrupt);
        }
        let o = row::compare_values(va, vb, col.opts);
        if o != Ordering::Equal {
            return Ok(o);
        }
    }
    Ok(Ordering::Equal)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::keycodec::ColumnOpts;
    use crate::row::ColumnType;
    use Value::{Float, Int, Null, Text};

    fn rec(row: &[Value<'_>]) -> Vec<u8> {
        let mut buf = [0u8; 64];
        encode_record(&mut buf, row).unwrap().to_vec()
    }

    #[test]
    fn record_bytes_for_a_small_row() {
        let row = [Text(b"Anna"), Int(7), Null, Float(1.0)];
        let bytes = rec(&row);
        assert_eq!(bytes.len(), record_len(&row));
        #[rustfmt::skip]
        assert_eq!(bytes, [
            4, // header_len: four serial types follow
            7, 1, 0, 2, // text of 4 bytes, int, NULL, float
            b'A', b'n', b'n', b'a', // text body
            14, // zigzag(7)
            0, 0, 0, 0, 0, 0, 0xf0, 0x3f, // 1.0, little-endian
        ]);
        validate_record(&bytes).unwrap();
        let mut small = vec![0u8; bytes.len() - 1];
        assert_eq!(encode_record(&mut small, &row), Err(RecordError::NoSpaceLeft));
    }

    #[test]
    fn decode_record_borrows_text_from_the_record() {
        let page = rec(&[Text(b"Anna"), Int(-7), Null, Float(-2.5)]);
        let back = decode_record(&page).unwrap();
        assert_eq!(back, [Text(b"Anna"), Int(-7), Null, Float(-2.5)]);
        // `page.fill(0xaa);` here would not compile while `back` is still used
        // below: "cannot borrow `page` as mutable because it is also borrowed
        // as immutable". That is the lifetime doing the arena's job.
        let Text(name) = back[0] else { panic!("text expected") };
        assert!(page.as_ptr_range().contains(&name.as_ptr())); // zero-copy
    }

    #[test]
    fn corrupt_records_are_rejected_never_trusted() {
        let mut bytes = rec(&[Text(b"Anna"), Int(7)]);
        for cut in 0..bytes.len() {
            assert!(validate_record(&bytes[..cut]).is_err());
        }
        bytes.push(0);
        assert_eq!(validate_record(&bytes), Err(RecordError::Corrupt)); // trailing byte
        assert_eq!(decode_record(&bytes), Err(RecordError::Corrupt));
        assert_eq!(validate_record(&[1, 200]), Err(RecordError::Truncated)); // serial type varint cut off
        assert_eq!(validate_record(&[1, 9, b'a']), Err(RecordError::Truncated)); // text of 6 bytes, 1 present
        assert_eq!(validate_record(&[9]), Err(RecordError::Truncated)); // header longer than the record
    }

    #[test]
    fn compare_records_stops_at_the_first_differing_column() {
        let schema = [
            Column {
                ty: ColumnType::Text,
                opts: ColumnOpts::ASC,
            },
            Column {
                ty: ColumnType::Int,
                opts: ColumnOpts::DESC,
            },
        ];
        let a = rec(&[Text(b"Ann"), Int(7)]);
        let b = rec(&[Text(b"Anna"), Int(9)]);
        let mut stats = CompareStats::default();
        assert_eq!(compare_records(&a, &b, &schema, Some(&mut stats)), Ok(Ordering::Less));
        assert_eq!(stats.columns_decoded, 2); // only the first column of each

        let c = rec(&[Text(b"Ann"), Int(9)]);
        assert_eq!(compare_records(&a, &c, &schema, Some(&mut stats)), Ok(Ordering::Greater)); // DESC: 7 after 9
        assert_eq!(
            stats,
            CompareStats {
                calls: 2,
                columns_decoded: 6
            }
        );

        // A record with the wrong column type for this schema is an error, not a crash.
        let d = rec(&[Int(1), Int(9)]);
        assert_eq!(compare_records(&a, &d, &schema, None), Err(RecordError::Corrupt));
        let short = rec(&[Text(b"Ann")]);
        assert_eq!(compare_records(&a, &short, &schema, None), Err(RecordError::Corrupt));
    }
}
