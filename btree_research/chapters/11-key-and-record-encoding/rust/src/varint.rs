//! Variable-length integers ("varints"): small numbers take few bytes.
//!
//! STANDALONE: depends on `std` only. Chapter 12 may copy this file as
//! `base_varint.rs`. Nothing here allocates. Twin of `zig/src/varint.zig`.
//!
//! Two formats are implemented:
//!
//!   LEB128 (the guide's own format, little-endian like the rest of our pages)
//!     7 payload bits per byte, least significant group first, high bit set
//!     on every byte except the last. 1 to 10 bytes for a u64.
//!       encoded_len(v) -> usize
//!       encode(buf, v) -> Result<usize, VarintError>      bytes written
//!       decode(buf) -> Result<(u64, usize), VarintError>  (value, bytes read)
//!       zigzag(i64) -> u64 / unzigzag(u64) -> i64         small negatives stay small
//!
//!   SQLite varint (what Turso reads and writes; shown for comparison)
//!     7 bits per byte, MOST significant group first; a 9th byte, if present,
//!     carries 8 bits. 1 to 9 bytes for a u64.
//!       sqlite_len(v), sqlite_encode(buf, v), sqlite_decode(buf)
//!
//! Neither format is order-preserving: comparing two varints as byte strings
//! does not compare the numbers (see the last test). Varints belong in record
//! bodies and cell headers; keys that must be compared with memcmp use
//! `keycodec.rs`.

pub const MAX_LEN: usize = 10; // ceil(64 / 7)
pub const SQLITE_MAX_LEN: usize = 9; // 8 * 7 + 8 = 64 bits

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum VarintError {
    /// The output buffer is too small (encode only).
    NoSpaceLeft,
    /// The buffer ended in the middle of a varint.
    Truncated,
    /// More than 64 bits of payload.
    Overflow,
    /// A longer encoding than necessary (for example `80 00` for 0).
    NonCanonical,
}

/// Number of bytes `encode` writes for `value`.
pub fn encoded_len(value: u64) -> usize {
    let mut n = 1;
    let mut v = value >> 7;
    while v != 0 {
        n += 1;
        v >>= 7;
    }
    n
}

/// Writes `value` at the start of `buf`. Writes nothing if it does not fit.
pub fn encode(buf: &mut [u8], value: u64) -> Result<usize, VarintError> {
    let n = encoded_len(value);
    if buf.len() < n {
        return Err(VarintError::NoSpaceLeft);
    }
    let mut v = value;
    for b in &mut buf[..n - 1] {
        *b = (v as u8) | 0x80; // low 7 bits + "more follows"
        v >>= 7;
    }
    buf[n - 1] = v as u8; // last group: high bit clear
    Ok(n)
}

/// Reads one varint from the start of `buf`.
///
/// Invariant kept by rejecting `NonCanonical`: every value has exactly one
/// encoding, so two records are equal as rows if and only if they are equal
/// as bytes. Without it `80 00` and `00` would both mean 0.
pub fn decode(buf: &[u8]) -> Result<(u64, usize), VarintError> {
    let mut value: u64 = 0;
    for i in 0..MAX_LEN {
        let Some(&b) = buf.get(i) else {
            return Err(VarintError::Truncated);
        };
        let group = u64::from(b & 0x7f);
        // The 10th byte holds bit 63 only: anything larger does not fit a u64.
        if i == MAX_LEN - 1 && group > 1 {
            return Err(VarintError::Overflow);
        }
        value |= group << (7 * i);
        if b & 0x80 == 0 {
            if i > 0 && b == 0 {
                return Err(VarintError::NonCanonical);
            }
            return Ok((value, i + 1));
        }
    }
    Err(VarintError::Overflow) // ten bytes, all with the continuation bit
}

/// Zigzag maps signed to unsigned so that numbers near zero stay short:
/// 0, -1, 1, -2, 2, ... become 0, 1, 2, 3, 4, ...
/// Without it -1 would be `ff ff ff ff ff ff ff ff ff 01` (ten bytes).
pub fn zigzag(v: i64) -> u64 {
    ((v << 1) ^ (v >> 63)) as u64 // `>>` on i64 is arithmetic: 0 or all ones
}

pub fn unzigzag(u: u64) -> i64 {
    ((u >> 1) as i64) ^ -((u & 1) as i64)
}

// ---- SQLite / Turso format -------------------------------------------------

pub fn sqlite_len(value: u64) -> usize {
    if value >> 56 != 0 {
        return 9; // needs the 8-bit ninth byte
    }
    encoded_len(value)
}

pub fn sqlite_encode(buf: &mut [u8], value: u64) -> Result<usize, VarintError> {
    let n = sqlite_len(value);
    if buf.len() < n {
        return Err(VarintError::NoSpaceLeft);
    }
    let mut v = value;
    if n == 9 {
        buf[8] = v as u8; // the last byte is a full byte
        v >>= 8;
    } else {
        buf[n - 1] = (v as u8) & 0x7f; // last group: high bit clear
        v >>= 7;
    }
    // Fill the remaining bytes from the back: big-endian groups.
    for b in buf[..(n - 1).min(8)].iter_mut().rev() {
        *b = (v as u8) | 0x80;
        v >>= 7;
    }
    Ok(n)
}

pub fn sqlite_decode(buf: &[u8]) -> Result<(u64, usize), VarintError> {
    let mut value: u64 = 0;
    for i in 0..8 {
        let Some(&b) = buf.get(i) else {
            return Err(VarintError::Truncated);
        };
        value = (value << 7) | u64::from(b & 0x7f);
        if b & 0x80 == 0 {
            return Ok((value, i + 1));
        }
    }
    let Some(&last) = buf.get(8) else {
        return Err(VarintError::Truncated);
    };
    // Same rule as Turso: a 9-byte varint whose value would have fitted in 8
    // bytes (top 8 of the 56 bits read so far are zero) is treated as corrupt.
    if value >> 48 == 0 {
        return Err(VarintError::NonCanonical);
    }
    Ok(((value << 8) | u64::from(last), 9))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Boundary values: every power of two, its neighbours, and the extremes.
    fn edge_values() -> Vec<u64> {
        let mut out = Vec::new();
        for bit in 0..64 {
            let p = 1u64 << bit;
            out.extend([p.wrapping_sub(1), p, p.wrapping_add(1)]);
        }
        out.extend([0, u64::MAX]);
        out
    }

    fn enc(v: u64) -> Vec<u8> {
        let mut buf = [0u8; MAX_LEN];
        let n = encode(&mut buf, v).unwrap();
        buf[..n].to_vec()
    }

    fn sqlite_enc(v: u64) -> Vec<u8> {
        let mut buf = [0u8; SQLITE_MAX_LEN];
        let n = sqlite_encode(&mut buf, v).unwrap();
        buf[..n].to_vec()
    }

    #[test]
    fn leb128_known_encodings() {
        assert_eq!(enc(0), [0x00]);
        assert_eq!(enc(127), [0x7f]);
        assert_eq!(enc(128), [0x80, 0x01]);
        assert_eq!(enc(300), [0xac, 0x02]);
        let max = enc(u64::MAX);
        assert_eq!(max.len(), 10);
        assert_eq!(max[9], 0x01);
    }

    #[test]
    fn leb128_round_trip_and_length_on_boundary_values() {
        let mut buf = [0u8; MAX_LEN];
        for v in edge_values() {
            let n = encode(&mut buf, v).unwrap();
            assert_eq!(n, encoded_len(v));
            assert_eq!(decode(&buf[..n]), Ok((v, n)));
            // One byte short is always an error, on both sides.
            assert_eq!(decode(&buf[..n - 1]), Err(VarintError::Truncated));
            assert_eq!(encode(&mut buf[..n - 1], v), Err(VarintError::NoSpaceLeft));
        }
    }

    #[test]
    fn leb128_rejects_overflow_and_non_canonical_input() {
        assert_eq!(decode(&[0x80, 0x00]), Err(VarintError::NonCanonical));
        assert_eq!(decode(&[0xff, 0x80, 0x00]), Err(VarintError::NonCanonical));
        let mut ten = [0xffu8; 10];
        ten[9] = 0x02;
        assert_eq!(decode(&ten), Err(VarintError::Overflow));
        ten[9] = 0x81;
        assert_eq!(decode(&ten), Err(VarintError::Overflow));
        assert_eq!(decode(&[]), Err(VarintError::Truncated));
    }

    #[test]
    fn zigzag_keeps_small_magnitudes_small_and_round_trips() {
        assert_eq!(zigzag(0), 0);
        assert_eq!(zigzag(-1), 1);
        assert_eq!(zigzag(1), 2);
        assert_eq!(zigzag(-2), 3);
        assert_eq!(zigzag(i64::MIN), u64::MAX);
        for v in [0, 1, -1, 63, -64, 64, i64::MAX, i64::MIN] {
            assert_eq!(unzigzag(zigzag(v)), v);
        }
        assert_eq!(encoded_len(zigzag(-64)), 1);
        assert_eq!(encoded_len(zigzag(64)), 2);
    }

    #[test]
    fn sqlite_varint_known_encodings_round_trip_corrupt_9_byte_form() {
        assert_eq!(sqlite_enc(127), [0x7f]);
        assert_eq!(sqlite_enc(128), [0x81, 0x00]);
        assert_eq!(sqlite_enc(300), [0x82, 0x2c]);
        assert_eq!(sqlite_enc(u64::MAX), [0xff; 9]);

        let mut buf = [0u8; SQLITE_MAX_LEN];
        for v in edge_values() {
            let n = sqlite_encode(&mut buf, v).unwrap();
            assert_eq!(n, sqlite_len(v));
            assert_eq!(sqlite_decode(&buf[..n]), Ok((v, n)));
            assert_eq!(sqlite_decode(&buf[..n - 1]), Err(VarintError::Truncated));
        }
        let mut small_in_nine = [0x80u8; 9];
        small_in_nine[8] = 0x05;
        assert_eq!(sqlite_decode(&small_in_nine), Err(VarintError::NonCanonical));
    }

    #[test]
    fn varints_are_not_order_preserving() {
        // 129 < 256, but 81 01 > 80 02 as byte strings.
        assert!(enc(129) > enc(256));
        // SQLite's big-endian groups do not rescue it: 16383 = ff 7f, 16384 = 81 80 00.
        assert!(sqlite_enc(16383) > sqlite_enc(16384));
    }
}
