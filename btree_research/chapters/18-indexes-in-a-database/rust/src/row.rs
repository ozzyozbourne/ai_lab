//! The one table of this chapter and the keys of its indexes.
//!
//! ```text
//!     CREATE TABLE orders (
//!         id       INTEGER PRIMARY KEY,   -- u32
//!         customer INTEGER,               -- u16
//!         day      INTEGER,               -- u16
//!         amount   INTEGER,               -- u16
//!         code     INTEGER UNIQUE         -- u16
//!     );
//!     CREATE INDEX by_customer_day ON orders (customer, day);
//! ```
//!
//! The B+tree copied from chapter 07 maps one u64 to one u64. That is enough
//! for a whole table engine if every key is a COMPOSITE packed into 64 bits:
//!
//! ```text
//!     by_customer_day key:  customer:16 | day:16 | locator:32
//!     by_code key:          0:16        | code:16 | locator:32
//!     heap primary key:     id:32                 | locator:32
//! ```
//!
//! Putting the first column in the most significant bits makes the integer
//! order equal to the column-by-column (lexicographic) order, which is all a
//! composite index is. Chapter 11 does the same for byte strings.
//!
//! The LOCATOR is whatever leads from an index entry back to its row. It is
//! the last part of every index key for two reasons: it makes entries with
//! equal columns distinct (chapter 07's tie-breaker), and it is the payload
//! the scan wants. What the locator IS depends on the layout (see table.rs):
//! the row id in a clustered table, the TID in a heap table.

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Row {
    pub id: u32,
    pub customer: u16,
    pub day: u16,
    pub amount: u16,
    pub code: u16,
}

/// Row id (clustered layout) or TID (heap layout).
pub type Locator = u32;

/// A clustered table stores the row IN the primary tree: key = id, value =
/// every other column. Four u16 columns happen to fill the u64 value slot; a
/// real engine stores a variable-length record there (chapter 11).
pub fn pack_row(row: Row) -> u64 {
    u64::from(row.customer) << 48
        | u64::from(row.day) << 32
        | u64::from(row.amount) << 16
        | u64::from(row.code)
}

pub fn unpack_row(id: u32, value: u64) -> Row {
    // `as u16` truncates, which is the point: keep the low 16 bits.
    Row {
        id,
        customer: (value >> 48) as u16,
        day: (value >> 32) as u16,
        amount: (value >> 16) as u16,
        code: value as u16,
    }
}

/// Key of `by_customer_day`.
pub fn customer_day_key(customer: u16, day: u16, locator: Locator) -> u64 {
    u64::from(customer) << 48 | u64::from(day) << 32 | u64::from(locator)
}

/// Key of a one-column index (`by_code`, and the heap layout's primary key).
pub fn column_key(value: u32, locator: Locator) -> u64 {
    u64::from(value) << 32 | u64::from(locator)
}

pub fn key_customer(key: u64) -> u16 {
    (key >> 48) as u16
}

pub fn key_day(key: u64) -> u16 {
    (key >> 32) as u16
}

/// The column of a one-column index key.
pub fn key_column(key: u64) -> u32 {
    (key >> 32) as u32
}

pub fn key_locator(key: u64) -> Locator {
    key as u32
}

/// A closed key interval [lo, hi]. Closed, not half-open, so that the range
/// of the largest prefix (customer 65535) needs no key beyond the u64 range.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct KeyRange {
    pub lo: u64,
    pub hi: u64,
}

impl KeyRange {
    pub const ALL: KeyRange = KeyRange {
        lo: 0,
        hi: u64::MAX,
    };
}

const ANY_LOCATOR: Locator = u32::MAX;

/// A prefix scan is a range scan: fix the leading column(s) and let every
/// later column, the locator included, run from its minimum to its maximum.
/// WHERE customer = c
pub fn customer_range(customer: u16) -> KeyRange {
    customer_days_range(customer, 0, u16::MAX)
}

/// WHERE customer = c AND day BETWEEN day_lo AND day_hi
/// Equality on the first column, a range on the second: still ONE contiguous
/// run of the index. (A range on the first column and equality on the second
/// would not be.)
pub fn customer_days_range(customer: u16, day_lo: u16, day_hi: u16) -> KeyRange {
    KeyRange {
        lo: customer_day_key(customer, day_lo, 0),
        hi: customer_day_key(customer, day_hi, ANY_LOCATOR),
    }
}

/// WHERE column = v on a one-column index: every locator under that value.
pub fn column_range(value: u32) -> KeyRange {
    KeyRange {
        lo: column_key(value, 0),
        hi: column_key(value, ANY_LOCATOR),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn packed_order_equals_column_by_column_order() {
        // (customer, day, locator) triples in ascending lexicographic order.
        let triples: [(u16, u16, u32); 11] = [
            (0, 0, 0),
            (0, 0, 1),
            (0, 1, 0),
            (0, 65535, 9),
            (1, 0, 0),
            (7, 12, 5),
            (7, 12, 10),
            (7, 13, 0),
            (8, 0, 99),
            (65535, 0, 0),
            (65535, 65535, 0xFFFF_FFFF),
        ];
        let mut previous: Option<u64> = None;
        for (customer, day, locator) in triples {
            let key = customer_day_key(customer, day, locator);
            if let Some(p) = previous {
                assert!(p < key);
            }
            previous = Some(key);
            assert_eq!(key_customer(key), customer);
            assert_eq!(key_day(key), day);
            assert_eq!(key_locator(key), locator);
        }
    }

    #[test]
    fn a_prefix_range_contains_exactly_the_keys_with_that_prefix() {
        let r = customer_range(7);
        assert!(customer_day_key(6, 65535, 0xFFFF_FFFF) < r.lo);
        assert!(customer_day_key(7, 0, 0) == r.lo);
        assert!(customer_day_key(7, 65535, 0xFFFF_FFFF) == r.hi);
        assert!(customer_day_key(8, 0, 0) > r.hi);
        // The largest prefix does not overflow.
        assert_eq!(customer_range(65535).hi, u64::MAX);

        let d = customer_days_range(7, 10, 20);
        assert!(customer_day_key(7, 9, 0xFFFF_FFFF) < d.lo);
        assert!(customer_day_key(7, 21, 0) > d.hi);
        assert!((d.lo..=d.hi).contains(&customer_day_key(7, 20, 123)));
    }

    #[test]
    fn a_row_survives_packing() {
        let row = Row {
            id: 17,
            customer: 9,
            day: 15,
            amount: 510,
            code: 170,
        };
        assert_eq!(unpack_row(17, pack_row(row)), row);
        let max = Row {
            id: 0xFFFF_FFFF,
            customer: 65535,
            day: 65535,
            amount: 65535,
            code: 65535,
        };
        assert_eq!(unpack_row(max.id, pack_row(max)), max);
    }
}
