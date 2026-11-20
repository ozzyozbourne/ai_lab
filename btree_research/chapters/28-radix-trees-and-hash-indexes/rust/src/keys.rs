//! Byte-comparable keys and the two small types every index in this chapter
//! shares.
//!
//! A radix tree never compares whole keys. It walks the key one byte at a time,
//! so "smaller key" has to mean "smaller byte string" (memcmp order, which is
//! also how Rust orders `[u8]`). Chapter 11 is the full story of
//! order-preserving encodings; this file has only the two encoders the chapter
//! needs, both modelled on DuckDB's ART keys.
use std::fmt::Write;

/// One key/value pair handed back by a scan. `key` is borrowed from the index.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Entry<'a> {
    pub key: &'a [u8],
    pub value: u64,
}

/// Result of a point lookup plus what it cost. `steps` means something
/// different per index (comparisons, nodes visited, slots probed); the unit is
/// documented at each `lookup`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Lookup {
    pub value: Option<u64>,
    pub steps: u32,
}

/// Big-endian fixed width: the most significant byte comes first, so byte
/// order equals numeric order. All keys have the same length, so no key can be
/// a prefix of another.
pub fn encode_u64(v: u64) -> [u8; 8] {
    v.to_be_bytes()
}

pub fn decode_u64(bytes: &[u8]) -> u64 {
    u64::from_be_bytes(bytes.try_into().expect("an encoded u64 is 8 bytes"))
}

/// Strings: escape 0x00 and 0x01 with a leading 0x01, then append a 0x00
/// terminator (the scheme of duckdb/src/execution/index/art/art_key.cpp:20-49).
///
/// Invariant this buys: no encoded key is a strict prefix of another encoded
/// key. "ab" and "abc" become "ab\x00" and "abc\x00", which differ at byte 2.
/// The ART stores values only at the end of a path, so it needs this.
/// Order is preserved: the terminator 0x00 sorts before every escaped byte.
pub fn encode_str(s: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(s.len() + 1);
    for &c in s {
        if c <= 1 {
            out.push(1);
        }
        out.push(c);
    }
    out.push(0);
    out
}

/// Print bytes the way the chapter's dumps show them: printable ASCII as is,
/// everything else (and the quote characters) as \xNN.
pub fn write_bytes(out: &mut String, bytes: &[u8]) {
    for &c in bytes {
        if (0x20..=0x7e).contains(&c) && c != b'"' && c != b'\'' && c != b'\\' {
            out.push(c as char);
        } else {
            write!(out, "\\x{c:02x}").expect("writing to a String cannot fail");
        }
    }
}

/// FNV-1a, 64 bit. Chosen because it is five lines and gives the same numbers
/// in Zig and Rust; a real hash index would use something stronger.
pub fn fnv1a(bytes: &[u8]) -> u64 {
    let mut h: u64 = 0xcbf2_9ce4_8422_2325;
    for &c in bytes {
        h ^= u64::from(c);
        h = h.wrapping_mul(0x0100_0000_01b3);
    }
    h
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn encode_u64_byte_order_equals_numeric_order() {
        let values = [0, 1, 255, 256, 65535, 65536, 1 << 40, u64::MAX];
        for pair in values.windows(2) {
            assert!(encode_u64(pair[0]) < encode_u64(pair[1]));
            assert_eq!(decode_u64(&encode_u64(pair[0])), pair[0]);
        }
    }

    #[test]
    fn encode_str_order_preserved_and_no_key_is_a_prefix_of_another() {
        // Already in the order we expect the encodings to have.
        let inputs: [&[u8]; 10] = [b"", b"\x00", b"\x00a", b"\x01", b"a", b"a\x00", b"a\x01", b"ab", b"abc", b"b"];
        let encoded: Vec<Vec<u8>> = inputs.iter().map(|s| encode_str(s)).collect();
        for i in 0..inputs.len() {
            for j in 0..inputs.len() {
                if i == j {
                    continue;
                }
                assert_eq!(i < j, encoded[i] < encoded[j]);
                assert!(!encoded[i].starts_with(&encoded[j]));
            }
        }
        assert_eq!(encoded[5], [b'a', 1, 0, 0]);
    }

    #[test]
    fn write_bytes_escapes_non_printable_bytes() {
        let mut out = String::new();
        write_bytes(&mut out, b"ab\x00\xff'");
        assert_eq!(out, "ab\\x00\\xff\\x27");
    }

    #[test]
    fn fnv1a_reference_values() {
        assert_eq!(fnv1a(b""), 0xcbf2_9ce4_8422_2325);
        assert_eq!(fnv1a(b"a"), 0xaf63_dc4c_8601_ec8c);
    }
}
