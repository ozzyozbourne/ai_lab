//! Seeded model test: random rows, three ways to order them, one answer.
//!
//! For every random pair of rows (a, b) the following must agree:
//!
//!   1. row::compare_rows(a, b)                     the oracle: values only
//!   2. key(a).cmp(key(b))                          byte-comparable keys
//!   3. record::compare_records(rec(a), rec(b))     comparator over records
//!
//! and both encodings must validate and round trip.
//!
//! The Zig twin (model.zig) draws from SplitMix64 in exactly the same order,
//! so both programs see the same rows and print the same counts.
use std::cmp::Ordering;

use crate::keycodec::ColumnOpts;
use crate::prng::SplitMix64;
use crate::record;
use crate::row::{self, Column, ColumnType, RowArena, Value};

/// Every option combination appears on some column.
pub const SCHEMA: [Column; 4] = [
    Column {
        ty: ColumnType::Text,
        opts: ColumnOpts {
            desc: true,
            nulls_first: true,
        },
    },
    Column {
        ty: ColumnType::Int,
        opts: ColumnOpts::ASC,
    },
    Column {
        ty: ColumnType::Float,
        opts: ColumnOpts::DESC,
    },
    Column {
        ty: ColumnType::Text,
        opts: ColumnOpts {
            desc: false,
            nulls_first: true,
        },
    },
];

/// A tiny alphabet that hits the escape byte, the terminator and 0xff often.
const ALPHABET: [u8; 6] = [0x00, 0x01, 0x02, b'a', b'b', 0xff];
const INT_EXTREMES: [i64; 4] = [i64::MIN, i64::MAX, -1, 0];
const FLOAT_SPECIALS: [f64; 8] = [f64::NEG_INFINITY, -1.5, -0.0, 0.0, 1.5, f64::INFINITY, f64::NAN, 1.0e300];

/// One random text column: `None` is NULL, otherwise the first `len` bytes.
#[derive(Debug, Clone, Copy, Default)]
struct RandomText {
    bytes: [u8; 3],
    len: Option<usize>,
}

impl RandomText {
    fn value(&self) -> Value<'_> {
        self.len.map_or(Value::Null, |n| Value::Text(&self.bytes[..n]))
    }
}

/// A random row for `SCHEMA`. It owns its text bytes; `values` lends them
/// out. (The Zig struct stores slices into itself and so must not move; here
/// the borrow checker would not let such a struct exist, and owning the data
/// plus a borrowing accessor is the idiom.)
#[derive(Debug, Clone, Copy, Default)]
pub struct RandomRow {
    texts: [RandomText; 2],
    int: Option<i64>,
    float: Option<f64>,
}

impl RandomRow {
    pub fn fill(&mut self, rng: &mut SplitMix64) {
        self.texts[0] = gen_text(rng);
        self.int = gen_int(rng);
        self.float = gen_float(rng);
        self.texts[1] = gen_text(rng);
    }

    pub fn values(&self) -> [Value<'_>; 4] {
        [
            self.texts[0].value(),
            self.int.map_or(Value::Null, Value::Int),
            self.float.map_or(Value::Null, Value::Float),
            self.texts[1].value(),
        ]
    }

    /// Copies the first `columns` columns from `other`.
    fn share_prefix(&mut self, other: &RandomRow, columns: usize) {
        if columns > 0 {
            self.texts[0] = other.texts[0];
        }
        if columns > 1 {
            self.int = other.int;
        }
        if columns > 2 {
            self.float = other.float;
        }
        if columns > 3 {
            self.texts[1] = other.texts[1];
        }
    }
}

fn gen_text(rng: &mut SplitMix64) -> RandomText {
    if rng.chance(1, 6) {
        return RandomText::default();
    }
    let n = rng.below(4) as usize;
    let mut bytes = [0u8; 3];
    for c in &mut bytes[..n] {
        *c = ALPHABET[rng.below(ALPHABET.len() as u64) as usize];
    }
    RandomText { bytes, len: Some(n) }
}

fn gen_int(rng: &mut SplitMix64) -> Option<i64> {
    if rng.chance(1, 6) {
        return None;
    }
    Some(match rng.below(4) {
        0 => rng.below(7) as i64 - 3,
        1 => rng.next_u64() as i64,
        2 => INT_EXTREMES[rng.below(INT_EXTREMES.len() as u64) as usize],
        _ => rng.below(1024) as i64 - 512,
    })
}

fn gen_float(rng: &mut SplitMix64) -> Option<f64> {
    if rng.chance(1, 6) {
        return None;
    }
    if rng.chance(1, 2) {
        return Some(FLOAT_SPECIALS[rng.below(FLOAT_SPECIALS.len() as u64) as usize]);
    }
    // Quarters between -8 and 7.75: exactly representable, many ties.
    let quarters = rng.below(64) as i64 - 32;
    Some(quarters as f64 / 4.0)
}

#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
pub struct Counts {
    pub lt: u64,
    pub eq: u64,
    pub gt: u64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Mismatch;

/// Checks `pairs` random pairs. One `RowArena` holds the row decoded from a
/// key and is cleared (capacity kept) before the next one.
pub fn check_pairs(seed: u64, pairs: u64) -> Result<Counts, Mismatch> {
    let mut arena = RowArena::new();
    let mut rng = SplitMix64::new(seed);
    let mut counts = Counts::default();
    for _ in 0..pairs {
        let mut a = RandomRow::default();
        let mut b = RandomRow::default();
        a.fill(&mut rng);
        b.fill(&mut rng);
        // Independent rows almost always differ in column 0. Copying a random
        // prefix of `a` into `b` makes later columns (and equality) matter.
        let shared = rng.below(SCHEMA.len() as u64 + 1) as usize;
        b.share_prefix(&a, shared);

        let rows = [a.values(), b.values()];
        let expected = row::compare_rows(&rows[0], &rows[1], &SCHEMA);
        match expected {
            Ordering::Less => counts.lt += 1,
            Ordering::Equal => counts.eq += 1,
            Ordering::Greater => counts.gt += 1,
        }

        let mut key_bufs = [[0u8; 40]; 2]; // worst case here is 34 bytes
        let mut rec_bufs = [[0u8; 40]; 2];
        let mut key_lens = [0; 2];
        let mut rec_lens = [0; 2];
        for i in 0..2 {
            let key = row::encode_key(&mut key_bufs[i], &rows[i], &SCHEMA).map_err(|_| Mismatch)?;
            let rec = record::encode_record(&mut rec_bufs[i], &rows[i]).map_err(|_| Mismatch)?;
            (key_lens[i], rec_lens[i]) = (key.len(), rec.len());

            row::validate_key(key, &SCHEMA).map_err(|_| Mismatch)?;
            record::validate_record(rec).map_err(|_| Mismatch)?;
            row::decode_key(&mut arena, key, &SCHEMA).map_err(|_| Mismatch)?;
            let from_rec = record::decode_record(rec).map_err(|_| Mismatch)?;
            if row::compare_rows(&rows[i], &arena.values(), &SCHEMA) != Ordering::Equal {
                return Err(Mismatch);
            }
            if from_rec.len() != SCHEMA.len() || row::compare_rows(&rows[i], &from_rec, &SCHEMA) != Ordering::Equal {
                return Err(Mismatch);
            }
        }

        let keys = [&key_bufs[0][..key_lens[0]], &key_bufs[1][..key_lens[1]]];
        let recs = [&rec_bufs[0][..rec_lens[0]], &rec_bufs[1][..rec_lens[1]]];
        if keys[0].cmp(keys[1]) != expected {
            return Err(Mismatch);
        }
        if record::compare_records(recs[0], recs[1], &SCHEMA, None) != Ok(expected) {
            return Err(Mismatch);
        }
    }
    Ok(counts)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn model_key_bytes_record_comparator_and_oracle_agree_several_seeds() {
        let mut total = Counts::default();
        for seed in [1, 2, 3, 42, 0xdead_beef] {
            let c = check_pairs(seed, 3000).unwrap();
            total.lt += c.lt;
            total.eq += c.eq;
            total.gt += c.gt;
        }
        // The generator must exercise all three outcomes, or the test proves little.
        assert!(total.lt > 1000 && total.gt > 1000 && total.eq > 1000);
    }

    #[test]
    fn model_generator_matches_the_zig_twin() {
        // Same seed, same draws, same counts as `zig build run` prints.
        assert_eq!(check_pairs(11, 2000), Ok(Counts { lt: 771, eq: 434, gt: 795 }));
    }
}
