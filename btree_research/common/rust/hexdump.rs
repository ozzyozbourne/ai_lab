//! Canonical hexdump of a byte slice, for expected-output files.
//!
//! Source of truth: common/rust/hexdump.rs (twin: common/zig/hexdump.zig).
//! A chapter copies this file and adds as its first line:
//!     // Copied from common/rust/hexdump.rs; do not edit here
//!
//! Format (the row layout of `hexdump -C`), 16 bytes per line:
//!
//!   00000000  42 54 72 65 65 00 01 02  03 04 05 06 07 08 09 0a  |BTree...........|
//!   00000010  ff 7e                                             |.~|
//!
//!   - 8 lowercase hex digits of offset, then two spaces
//!   - each byte as two lowercase hex digits + one space; one extra space
//!     after the 8th byte; missing bytes of a short last line are 3 spaces
//!   - one space, then '|' + ASCII + '|' where bytes outside 0x20..0x7e are '.'
//!   - every line ends with '\n'; empty input gives the empty string
//!   - unlike `hexdump -C`: repeated lines are never squeezed into '*', and
//!     there is no trailing total-length line

const DIGITS: &[u8; 16] = b"0123456789abcdef";

pub fn hexdump(bytes: &[u8]) -> String {
    let mut out = String::new();
    // `chunks(16)` yields slices of 16 bytes; the last one may be shorter.
    for (line_no, line) in bytes.chunks(16).enumerate() {
        let offset = line_no * 16;

        // Offset column: 8 hex digits, most significant first.
        for shift in [28, 24, 20, 16, 12, 8, 4, 0] {
            out.push(DIGITS[(offset >> shift) & 0xF] as char);
        }
        out.push_str("  ");

        // Hex column: always 16 cells wide so the ASCII column lines up.
        for i in 0..16 {
            match line.get(i) {
                Some(&b) => {
                    out.push(DIGITS[usize::from(b >> 4)] as char);
                    out.push(DIGITS[usize::from(b & 0xF)] as char);
                    out.push(' ');
                }
                None => out.push_str("   "),
            }
            if i == 7 {
                out.push(' ');
            }
        }

        // ASCII column.
        out.push_str(" |");
        for &b in line {
            out.push(if (0x20..=0x7e).contains(&b) {
                b as char
            } else {
                '.'
            });
        }
        out.push_str("|\n");
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hexdump_layout() {
        assert_eq!(hexdump(b""), "");
        let mut bytes = b"BTree".to_vec();
        bytes.extend_from_slice(&[0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 0xff, 0x7e]);
        let expected = "\
00000000  42 54 72 65 65 00 01 02  03 04 05 06 07 08 09 0a  |BTree...........|
00000010  ff 7e                                             |.~|
";
        assert_eq!(hexdump(&bytes), expected);
    }
}
