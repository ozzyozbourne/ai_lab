//! The metapage: the ONE place that is overwritten, and how that stays safe.
//!
//! Every other page is written once into a free slot and never changed while
//! a committed root can reach it. But "which root is current" has to live at
//! a fixed address, or nobody could find it after a restart. So the metapage
//! has TWO slots and commits alternate between them:
//!
//! ```text
//! commit of txn 7 writes slot 1   (7 % 2), slot 0 still holds txn 6
//! commit of txn 8 writes slot 0   (8 % 2), slot 1 still holds txn 7
//! ```
//!
//! A commit therefore never overwrites the slot of the newest committed
//! transaction. If the write is torn (chapter 21), the checksum of the half
//! written slot fails and the reader falls back to the other slot: the
//! previous commit, complete and untouched.
//!
//! The older slot is also the fallback when the NEWER one becomes unreadable
//! later (a bad sector). That only helps if the tree it names is still
//! complete, so the database keeps the pages of both slots' trees unwritten:
//! see `Db::previous` and the reclamation rule in db.rs.
//!
//! Slot layout, 32 bytes, little-endian:
//!
//! ```text
//! 0   u64  txn_id      id of the transaction that wrote this slot
//! 8   u32  root        page id of the root, 0xFFFFFFFF = empty tree
//! 12  u32  height      levels (0 = empty, 1 = the root is a leaf)
//! 16  u64  count       number of entries
//! 24  u32  page_count  size of the page store in pages at this commit
//! 28  u32  checksum    CRC-32 of bytes 0..28
//! ```

use crate::base_node::PageId;
use crate::crc32::crc32;

pub const SLOT_SIZE: usize = 32;
pub type Slots = [[u8; SLOT_SIZE]; 2];

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Meta {
    pub txn_id: u64,
    pub root: PageId,
    pub height: u32,
    pub count: u64,
    pub page_count: u32,
}

impl Meta {
    pub fn encode(&self) -> [u8; SLOT_SIZE] {
        let mut b = [0u8; SLOT_SIZE];
        b[0..8].copy_from_slice(&self.txn_id.to_le_bytes());
        b[8..12].copy_from_slice(&self.root.raw().to_le_bytes());
        b[12..16].copy_from_slice(&self.height.to_le_bytes());
        b[16..24].copy_from_slice(&self.count.to_le_bytes());
        b[24..28].copy_from_slice(&self.page_count.to_le_bytes());
        let crc = crc32(&b[0..28]);
        b[28..32].copy_from_slice(&crc.to_le_bytes());
        b
    }

    /// `None` if the checksum does not match: a slot that was never written
    /// (all zeroes: the CRC of 28 zero bytes is not 0) or a torn write.
    pub fn decode(b: &[u8; SLOT_SIZE]) -> Option<Meta> {
        if Meta::checksum(b) != crc32(&b[0..28]) {
            return None;
        }
        Some(Meta {
            txn_id: u64::from_le_bytes(b[0..8].try_into().unwrap()),
            root: PageId::from_raw(u32::from_le_bytes(b[8..12].try_into().unwrap())),
            height: u32::from_le_bytes(b[12..16].try_into().unwrap()),
            count: u64::from_le_bytes(b[16..24].try_into().unwrap()),
            page_count: u32::from_le_bytes(b[24..28].try_into().unwrap()),
        })
    }

    /// The rule a reader (or a restart) uses: of the slots whose checksum is
    /// valid, the one with the higher transaction id. `None` = no valid slot.
    pub fn pick(slots: &Slots) -> Option<Meta> {
        match (Meta::decode(&slots[0]), Meta::decode(&slots[1])) {
            (Some(a), Some(b)) => Some(if a.txn_id > b.txn_id { a } else { b }),
            (a, b) => a.or(b),
        }
    }

    /// The valid slot that `pick` did NOT choose, if it holds an older
    /// transaction: the root a restart falls back to when the chosen slot
    /// cannot be read any more.
    pub fn fallback(slots: &Slots) -> Option<Meta> {
        let (a, b) = (Meta::decode(&slots[0])?, Meta::decode(&slots[1])?);
        if a.txn_id == b.txn_id {
            return None;
        }
        Some(if a.txn_id < b.txn_id { a } else { b })
    }

    pub fn checksum(b: &[u8; SLOT_SIZE]) -> u32 {
        u32::from_le_bytes(b[28..32].try_into().unwrap())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn encode_and_decode_round_trip_a_flipped_bit_is_detected() {
        let m = Meta {
            txn_id: 7,
            root: PageId::from_index(3),
            height: 2,
            count: 9,
            page_count: 12,
        };
        let mut b = m.encode();
        assert_eq!(Meta::decode(&b), Some(m));
        b[9] ^= 0x10;
        assert_eq!(Meta::decode(&b), None);
    }

    #[test]
    fn pick_takes_the_valid_slot_with_the_higher_transaction_id() {
        let old = Meta {
            txn_id: 6,
            root: PageId::from_index(1),
            height: 1,
            count: 2,
            page_count: 4,
        };
        let new = Meta {
            txn_id: 7,
            root: PageId::from_index(2),
            height: 1,
            count: 3,
            page_count: 4,
        };
        let mut slots: Slots = [[0; SLOT_SIZE]; 2];
        assert_eq!(Meta::pick(&slots), None); // never written
        slots[0] = old.encode();
        assert_eq!(Meta::pick(&slots), Some(old)); // one valid slot
        assert_eq!(Meta::fallback(&slots), None); // nothing to fall back to
        slots[1] = new.encode();
        assert_eq!(Meta::pick(&slots), Some(new)); // higher id wins
        assert_eq!(Meta::fallback(&slots), Some(old));
        slots[1][0] ^= 0xFF; // torn write of the newest commit
        assert_eq!(Meta::pick(&slots), Some(old)); // fall back
    }
}
