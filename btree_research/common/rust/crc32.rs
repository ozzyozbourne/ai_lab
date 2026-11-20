//! CRC-32 (IEEE 802.3: the checksum of zlib, gzip, PNG, Ethernet), by hand.
//!
//! Source of truth: common/rust/crc32.rs (twin: common/zig/crc32.zig).
//! A chapter copies this file and adds as its first line:
//!     // Copied from common/rust/crc32.rs; do not edit here
//!
//! Parameters: reflected (bits processed least-significant first),
//! polynomial 0xEDB88320 (0x04C11DB7 bit-reversed), initial value 0xFFFFFFFF,
//! final XOR 0xFFFFFFFF. Check value: crc32(b"123456789") == 0xCBF43926.
//! On-disk chapters use it to detect torn or corrupted pages.

/// TABLE[b] = the CRC register after feeding the single byte b into a zero
/// register. Built once by the compiler (`const fn`): 256 entries, 8 shift
/// steps each; nothing is computed at run time.
const TABLE: [u32; 256] = make_table();

const fn make_table() -> [u32; 256] {
    let mut table = [0u32; 256];
    let mut i = 0;
    // `for` loops are not allowed in const fn yet, hence `while`.
    while i < 256 {
        let mut c = i as u32;
        let mut bit = 0;
        while bit < 8 {
            // If the low bit is set, shift and "subtract" (XOR) the polynomial.
            c = if c & 1 != 0 {
                (c >> 1) ^ 0xEDB8_8320
            } else {
                c >> 1
            };
            bit += 1;
        }
        table[i] = c;
        i += 1;
    }
    table
}

/// CRC-32 of `bytes` in one call.
pub fn crc32(bytes: &[u8]) -> u32 {
    crc32_update(0, bytes)
}

/// Continue a checksum: crc32_update(crc32(a), b) == crc32(a followed by b).
/// Start with `crc = 0`. (Same convention as zlib's crc32().)
pub fn crc32_update(crc: u32, bytes: &[u8]) -> u32 {
    let mut c = !crc; // undo the final XOR of the previous call (or apply init)
    for &byte in bytes {
        // Low 8 bits of the register XOR the next byte select a table entry.
        c = TABLE[usize::from(c as u8 ^ byte)] ^ (c >> 8);
    }
    !c // final XOR
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn known_vectors() {
        assert_eq!(crc32(b""), 0x0000_0000);
        assert_eq!(crc32(b"a"), 0xE8B7_BE43);
        assert_eq!(crc32(b"123456789"), 0xCBF4_3926);
        assert_eq!(
            crc32(b"The quick brown fox jumps over the lazy dog"),
            0x414F_A339
        );
    }

    #[test]
    fn chunked_updates_match_one_shot() {
        let data: Vec<u8> = (0..1000u32)
            .map(|i| (i.wrapping_mul(31).wrapping_add(7)) as u8)
            .collect();
        for n in [0, 1, 2, 15, 16, 17, 255, 256, 1000] {
            let half = n / 2;
            assert_eq!(
                crc32_update(crc32(&data[..half]), &data[half..n]),
                crc32(&data[..n])
            );
        }
    }
}
