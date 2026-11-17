//! Checksummed pages: how a reader tells a good page from a damaged one.
//!
//! Layout of a 4096-byte page:
//!
//! ```text
//! 0 ......................... 4091 | 4092 .. 4095
//! payload (PAYLOAD_SIZE bytes)     | CRC-32, little-endian
//! ```
//!
//! The CRC covers the page number (8 bytes, little-endian) followed by the
//! payload. Mixing in the page number means a perfectly good page that lands
//! at the wrong address (a misdirected write) or is read from the wrong
//! address also fails verification.
//!
//! ```text
//! seal(&mut page, page_no)   compute and store the checksum; call it last,
//!                            right before write_page
//! verify(&page, page_no)     Ok, Blank (all zeroes: never written) or Corrupt
//! read_checked(storage, page_no, &mut out)   read_page + verify; a page past
//!                            the end of the store counts as blank
//! ```
//!
//! What a checksum does NOT do: it cannot repair anything, and it cannot tell
//! a stale-but-intact page (a lost write) from the current one. Detection
//! only; repair needs a second copy (doublewrite.rs here, the log in ch. 22).

use crate::crc32::{crc32, crc32_update};
use crate::storage::{PAGE_SIZE, Page, Storage, StorageError};

pub const CHECKSUM_SIZE: usize = 4;
/// Bytes of a page that the layers above may use.
pub const PAYLOAD_SIZE: usize = PAGE_SIZE - CHECKSUM_SIZE; // 4092

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Check {
    Ok,
    Blank,
    Corrupt,
}

impl Check {
    /// Lower-case name, as printed by the demo.
    pub fn name(self) -> &'static str {
        match self {
            Check::Ok => "ok",
            Check::Blank => "blank",
            Check::Corrupt => "corrupt",
        }
    }
}

/// CRC-32 over (page_no as 8 little-endian bytes) ++ payload.
pub fn checksum(page: &Page, page_no: u64) -> u32 {
    crc32_update(crc32(&page_no.to_le_bytes()), &page[..PAYLOAD_SIZE])
}

/// The checksum stored in the page's last four bytes.
pub fn stored_checksum(page: &Page) -> u32 {
    u32::from_le_bytes(page[PAYLOAD_SIZE..].try_into().expect("4 bytes"))
}

/// Stamp the page for address `page_no`. Any later change to the payload
/// requires sealing again.
pub fn seal(page: &mut Page, page_no: u64) {
    let sum = checksum(page, page_no);
    page[PAYLOAD_SIZE..].copy_from_slice(&sum.to_le_bytes());
}

pub fn verify(page: &Page, page_no: u64) -> Check {
    if stored_checksum(page) == checksum(page, page_no) {
        return Check::Ok;
    }
    // A page of zeroes was never written (a hole, or space past the end). It
    // is not damage, but it is not data either: the caller decides.
    if page.iter().all(|&b| b == 0) {
        return Check::Blank;
    }
    Check::Corrupt
}

/// Read a page and classify it. A page at or past `storage.size()` is
/// returned as zeroes and `Blank`, which is what recovery code wants.
pub fn read_checked(
    storage: &mut dyn Storage,
    page_no: u64,
    out: &mut Page,
) -> Result<Check, StorageError> {
    if page_no >= storage.size() {
        out.fill(0);
        return Ok(Check::Blank);
    }
    storage.read_page(page_no, out)?;
    Ok(verify(out, page_no))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::storage::{SECTOR_SIZE, SECTORS_PER_PAGE};

    #[test]
    fn seal_then_verify() {
        let mut page: Page = [0; PAGE_SIZE];
        assert_eq!(verify(&page, 5), Check::Blank);
        page[..5].copy_from_slice(b"hello");
        assert_eq!(verify(&page, 5), Check::Corrupt); // not sealed yet
        seal(&mut page, 5);
        assert_eq!(verify(&page, 5), Check::Ok);
        assert_eq!(stored_checksum(&page), checksum(&page, 5));
    }

    #[test]
    fn the_page_number_is_part_of_the_checksum() {
        let mut page: Page = [0; PAGE_SIZE];
        page[..5].copy_from_slice(b"hello");
        seal(&mut page, 5);
        assert_eq!(verify(&page, 6), Check::Corrupt); // right bytes, wrong place
    }

    #[test]
    fn an_all_zero_payload_sealed_for_a_page_is_ok_not_blank() {
        // The CRC of a zero payload is not zero, so a deliberately written
        // empty page is distinguishable from a hole.
        let mut page: Page = [0; PAGE_SIZE];
        seal(&mut page, 0);
        assert_ne!(stored_checksum(&page), 0);
        assert_eq!(verify(&page, 0), Check::Ok);
    }

    #[test]
    fn every_single_bit_flip_is_detected() {
        let mut page: Page = [0; PAGE_SIZE];
        for (i, b) in page.iter_mut().enumerate() {
            *b = i.wrapping_mul(31) as u8;
        }
        seal(&mut page, 9);
        // CRC-32 detects all single-bit errors; try one bit in every byte.
        for i in 0..PAGE_SIZE {
            page[i] ^= 1 << (i % 8);
            assert_eq!(verify(&page, 9), Check::Corrupt);
            page[i] ^= 1 << (i % 8);
        }
        assert_eq!(verify(&page, 9), Check::Ok);
    }

    #[test]
    fn every_torn_mix_of_two_sealed_versions_is_detected() {
        let mut old: Page = [b'A'; PAGE_SIZE];
        let mut new: Page = [b'B'; PAGE_SIZE];
        seal(&mut old, 3);
        seal(&mut new, 3);
        for mask in 1u16..255 {
            // all 254 proper sector subsets
            let mut torn = old;
            for s in 0..SECTORS_PER_PAGE {
                if mask & (1 << s) != 0 {
                    let at = s * SECTOR_SIZE;
                    torn[at..at + SECTOR_SIZE].copy_from_slice(&new[at..at + SECTOR_SIZE]);
                }
            }
            assert_eq!(verify(&torn, 3), Check::Corrupt);
        }
    }
}
