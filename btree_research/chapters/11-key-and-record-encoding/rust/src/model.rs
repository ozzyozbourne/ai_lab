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
//!
//! Two generators:
//!
//!   check_pairs            one fixed four-column schema and a tiny alphabet;
//!                          small enough to print, used by `cargo run` (section 8)
//!   check_random_schemas   tests only: a new random schema for every pair (any
//!                          type with any options), the bytes that collide with
//!                          the key framing under ASC and under DESC, longer
//!                          strings, floats at every edge of the format, and
//!                          every truncation of every key and record
use std::cmp::Ordering;

use crate::keycodec::ColumnOpts;
use crate::prng::SplitMix64;
use crate::record;
use crate::row::{self, Column, ColumnType, RowArena, Value};

/// Every option combination appears on some column (but not on every type:
/// `check_random_schemas` in the tests covers that).
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
/// (0xfe, which becomes the escape byte once a DESC column is inverted, is in
/// `WIDE_ALPHABET`; adding it here would change the printed counts.)
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

    // ---- the wide generator ---------------------------------------------------

    const WIDE_MAX_COLS: usize = 5;
    const WIDE_MAX_TEXT: usize = 24;
    const WIDE_MAX_KEY: usize = WIDE_MAX_COLS * (2 * WIDE_MAX_TEXT + 2);

    /// 00 terminator, 01 escape and value tag, 02 NULLS LAST tag; fd fe ff are the
    /// bytes that turn into 02 01 00 when a DESC column is inverted.
    const WIDE_ALPHABET: [u8; 7] = [0x00, 0x01, 0x02, 0xfd, 0xfe, 0xff, b'a'];

    const WIDE_INTS: [i64; 20] = [
        i64::MIN,
        i64::MIN + 1,
        -0x1_0000_0001,
        -0x8000_0000,
        -257,
        -256,
        -255,
        -129,
        -128,
        -1,
        0,
        1,
        127,
        128,
        255,
        256,
        0x7fff_ffff,
        0x1_0000_0000,
        i64::MAX - 1,
        i64::MAX,
    ];

    /// Both zeros, smallest and largest subnormals, smallest normal, largest
    /// finite, infinities, NaNs of both signs with and without payload,
    /// neighbours of 1.0, 2^53.
    const WIDE_FLOAT_BITS: [u64; 28] = [
        0x0000000000000000,
        0x8000000000000000,
        0x0000000000000001,
        0x8000000000000001,
        0x000fffffffffffff,
        0x800fffffffffffff,
        0x0010000000000000,
        0x8010000000000000,
        0x7fefffffffffffff,
        0xffefffffffffffff,
        0x7ff0000000000000,
        0xfff0000000000000,
        0x7ff0000000000001,
        0xfff0000000000001,
        0x7ff8000000000000,
        0xfff8000000000000,
        0x7fffffffffffffff,
        0xffffffffffffffff,
        0x3ff0000000000000,
        0xbff0000000000000,
        0x3ff0000000000001,
        0xbff0000000000001,
        0x3fefffffffffffff,
        0xbfefffffffffffff,
        0x4340000000000000,
        0xc340000000000000,
        0x7ff4000000000000,
        0xfff000000000beef,
    ];

    /// A value that owns its text, so that a row can be built column by column.
    #[derive(Debug, Clone, PartialEq)]
    enum Owned {
        Null,
        Int(i64),
        Float(f64),
        Text(Vec<u8>),
    }

    impl Owned {
        fn value(&self) -> Value<'_> {
            match self {
                Owned::Null => Value::Null,
                Owned::Int(x) => Value::Int(*x),
                Owned::Float(x) => Value::Float(*x),
                Owned::Text(s) => Value::Text(s),
            }
        }
    }

    fn wide_int(rng: &mut SplitMix64) -> i64 {
        match rng.below(4) {
            0 => WIDE_INTS[rng.below(WIDE_INTS.len() as u64) as usize],
            1 => rng.next_u64() as i64,
            2 => 1i64 << rng.below(63),
            _ => rng.below(7) as i64 - 3,
        }
    }

    fn wide_float(rng: &mut SplitMix64) -> f64 {
        match rng.below(4) {
            0 => f64::from_bits(WIDE_FLOAT_BITS[rng.below(WIDE_FLOAT_BITS.len() as u64) as usize]),
            1 => f64::from_bits(rng.next_u64()), // any bit pattern
            2 => {
                // Within 2 ulp of a special pattern.
                let special = WIDE_FLOAT_BITS[rng.below(WIDE_FLOAT_BITS.len() as u64) as usize];
                f64::from_bits(special.wrapping_add(rng.below(5)).wrapping_sub(2))
            }
            _ => (rng.below(9) as i64 - 4) as f64 / 2.0,
        }
    }

    /// Mostly up to 4 bytes (ties and prefixes are common), one in four up to 24.
    fn wide_text(rng: &mut SplitMix64) -> Vec<u8> {
        let n = if rng.chance(1, 4) { rng.below(WIDE_MAX_TEXT as u64 + 1) } else { rng.below(5) };
        let mut text = Vec::new();
        for _ in 0..n {
            let c = if rng.chance(1, 4) { rng.next_u64() as u8 } else { WIDE_ALPHABET[rng.below(WIDE_ALPHABET.len() as u64) as usize] };
            text.push(c);
        }
        text
    }

    /// FNV-1a over every key and record produced: equal in Zig and in Rust only
    /// if the two implementations write the same bytes for the same rows.
    fn fnv1a(hash: &mut u64, bytes: &[u8]) {
        for &b in bytes {
            *hash ^= u64::from(b);
            *hash = hash.wrapping_mul(0x100_0000_01b3);
        }
    }

    /// Like `check_pairs`, but with a new random schema for every pair, and with
    /// stricter checks: exact lengths, key decode-then-encode is the identity on
    /// bytes, records round trip to the bit, and every truncation is an error.
    fn check_random_schemas(seed: u64, pairs: u64) -> (Counts, u64) {
        const TYPES: [ColumnType; 3] = [ColumnType::Int, ColumnType::Float, ColumnType::Text];
        let mut arena = RowArena::new();
        let mut rng = SplitMix64::new(seed);
        let mut counts = Counts::default();
        let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
        for _ in 0..pairs {
            let ncol = 1 + rng.below(WIDE_MAX_COLS as u64) as usize;
            let mut schema = Vec::new();
            for _ in 0..ncol {
                let ty = TYPES[rng.below(3) as usize];
                let desc = rng.chance(1, 2);
                let nulls_first = rng.chance(1, 2);
                schema.push(Column {
                    ty,
                    opts: ColumnOpts { desc, nulls_first },
                });
            }

            let mut owned: [Vec<Owned>; 2] = [Vec::new(), Vec::new()];
            for row in &mut owned {
                for col in &schema {
                    row.push(if rng.chance(1, 7) {
                        Owned::Null
                    } else {
                        match col.ty {
                            ColumnType::Int => Owned::Int(wide_int(&mut rng)),
                            ColumnType::Float => Owned::Float(wide_float(&mut rng)),
                            ColumnType::Text => Owned::Text(wide_text(&mut rng)),
                        }
                    });
                }
            }
            let shared = rng.below(ncol as u64 + 1) as usize;
            let (a, b) = owned.split_at_mut(1);
            b[0][..shared].clone_from_slice(&a[0][..shared]);
            // Often make one text of `b` a prefix of `a`'s, or that plus one byte.
            let pc = rng.below(ncol as u64) as usize;
            if let Owned::Text(s) = &a[0][pc]
                && rng.chance(1, 2)
            {
                let mut t = s[..rng.below(s.len() as u64 + 1) as usize].to_vec();
                if t.len() < WIDE_MAX_TEXT && rng.chance(1, 2) {
                    t.push(WIDE_ALPHABET[rng.below(WIDE_ALPHABET.len() as u64) as usize]);
                }
                b[0][pc] = Owned::Text(t);
            }
            let rows: [Vec<Value<'_>>; 2] = [
                owned[0].iter().map(Owned::value).collect(),
                owned[1].iter().map(Owned::value).collect(),
            ];

            let expected = row::compare_rows(&rows[0], &rows[1], &schema);
            match expected {
                Ordering::Less => counts.lt += 1,
                Ordering::Equal => counts.eq += 1,
                Ordering::Greater => counts.gt += 1,
            }

            let mut keys = Vec::new();
            let mut recs = Vec::new();
            for row in &rows {
                let mut key_buf = [0u8; WIDE_MAX_KEY];
                let mut rec_buf = [0u8; WIDE_MAX_KEY];
                let key = row::encode_key(&mut key_buf, row, &schema).unwrap();
                let rec = record::encode_record(&mut rec_buf, row).unwrap();
                fnv1a(&mut hash, key);
                fnv1a(&mut hash, rec);
                assert_eq!(key.len(), row::key_len(row));
                assert_eq!(rec.len(), record::record_len(row));

                // Key: validates, decodes to an equal row, and that row encodes to
                // the very same bytes (one row, one key).
                row::validate_key(key, &schema).unwrap();
                row::decode_key(&mut arena, key, &schema).unwrap();
                let from_key = arena.values();
                assert_eq!(row::compare_rows(row, &from_key, &schema), Ordering::Equal);
                let mut again = [0u8; WIDE_MAX_KEY];
                assert_eq!(row::encode_key(&mut again, &from_key, &schema).unwrap(), key);

                // Record: validates and round trips to the bit, -0.0 and NaN
                // payloads included (the key normalises them, the record must not).
                record::validate_record(rec).unwrap();
                let from_rec = record::decode_record(rec).unwrap();
                assert_eq!(from_rec.len(), ncol);
                for (want, got) in row.iter().zip(&from_rec) {
                    match (want, got) {
                        (Value::Float(x), Value::Float(y)) => assert_eq!(x.to_bits(), y.to_bits()),
                        _ => assert_eq!(want, got),
                    }
                }

                // These bytes come from disk: cut anywhere, both must be rejected.
                for cut in 0..key.len() {
                    assert_eq!(
                        row::validate_key(&key[..cut], &schema),
                        Err(row::RowError::Key(crate::keycodec::KeyError::Truncated))
                    );
                    assert!(row::decode_key(&mut arena, &key[..cut], &schema).is_err());
                }
                for cut in 0..rec.len() {
                    assert!(record::validate_record(&rec[..cut]).is_err());
                    assert!(record::decode_record(&rec[..cut]).is_err());
                }
                keys.push(key.to_vec());
                recs.push(rec.to_vec());
            }

            assert_eq!(keys[0].cmp(&keys[1]), expected, "{schema:?}\n  {:?}\n  {:?}", rows[0], rows[1]);
            assert_eq!(record::compare_records(&recs[0], &recs[1], &schema, None), Ok(expected));
        }
        (counts, hash)
    }

    #[test]
    fn model_random_schemas_framing_bytes_long_strings_float_edges_every_truncation() {
        let mut total = Counts::default();
        for seed in [1, 2, 3] {
            let (c, _) = check_random_schemas(seed, 2000);
            total.lt += c.lt;
            total.eq += c.eq;
            total.gt += c.gt;
        }
        assert!(total.lt > 1000 && total.gt > 1000 && total.eq > 500);
    }

    #[test]
    fn model_random_schemas_produce_the_same_bytes_as_the_zig_twin() {
        // Same seed, same draws; the hash covers every key and record byte.
        let (c, hash) = check_random_schemas(11, 2000);
        assert_eq!((c, hash), (Counts { lt: 707, eq: 550, gt: 743 }, 0x2a9a_990c_169d_c507));
    }

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
