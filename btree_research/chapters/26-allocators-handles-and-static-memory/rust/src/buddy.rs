//! A binary buddy allocator (twin of zig/src/buddy.zig; textbook algorithm, Knuth
//! TAOCP 2.5).
//!
//! The Zig version manages a caller-provided buffer and implements `std.mem.Allocator`.
//! Rust's `Allocator` trait is unstable, so this version owns its bytes in a `Vec<u8>`
//! and hands out OFFSETS: `alloc` returns where the block starts, `bytes_mut` turns
//! an offset back into a slice. Offsets are to a byte heap what handles are to a slab.
//!
//! A block of order k is `min_block << k` bytes and starts at a multiple of its size.
//! A request is rounded up to a power of two; a larger block is split when needed and
//! the unused halves ("buddies") go on free lists. On free, a block whose buddy is
//! also free merges with it, repeatedly.

const NONE: u32 = u32::MAX;

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum State {
    /// Not the first minimum block of any block.
    Inside,
    /// First minimum block of a free block (which is on a free list).
    Free,
    /// First minimum block of an allocated block.
    Used,
}

pub struct Buddy {
    min_block: usize,
    max_order: usize,
    bytes: Vec<u8>,
    /// Per minimum block; `order` and the links are meaningful only where a block starts.
    state: Vec<State>,
    order: Vec<u8>,
    next: Vec<u32>,
    prev: Vec<u32>,
    /// One doubly linked free list per order (doubly linked so that a buddy can be
    /// unlinked from the middle when it merges).
    heads: Vec<u32>,
    /// Bytes the callers asked for, and bytes actually set aside for them. The
    /// difference is internal fragmentation, the cost of power-of-two rounding.
    pub requested: usize,
    pub granted: usize,
    /// Request length per block start, so that `free` needs only the offset.
    lens: Vec<usize>,
}

#[derive(Debug, PartialEq, Eq)]
pub struct Invalid;

impl Buddy {
    /// A heap of `1 << heap_log2` bytes with minimum block `1 << min_log2`.
    pub fn new(heap_log2: u32, min_log2: u32) -> Buddy {
        assert!(heap_log2 >= min_log2 && heap_log2 - min_log2 <= 20);
        let max_order = (heap_log2 - min_log2) as usize;
        let leaf_count = 1usize << max_order;
        let mut buddy = Buddy {
            min_block: 1 << min_log2,
            max_order,
            bytes: vec![0; 1 << heap_log2],
            state: vec![State::Inside; leaf_count],
            order: vec![0; leaf_count],
            next: vec![NONE; leaf_count],
            prev: vec![NONE; leaf_count],
            heads: vec![NONE; max_order + 1],
            requested: 0,
            granted: 0,
            lens: vec![0; leaf_count],
        };
        buddy.push_free(0, max_order); // the whole heap is one free block
        buddy
    }

    fn block_size(&self, k: usize) -> usize {
        self.min_block << k
    }

    fn push_free(&mut self, block: u32, k: usize) {
        let b = block as usize;
        self.state[b] = State::Free;
        self.order[b] = k as u8;
        self.prev[b] = NONE;
        self.next[b] = self.heads[k];
        if self.heads[k] != NONE {
            self.prev[self.heads[k] as usize] = block;
        }
        self.heads[k] = block;
    }

    fn unlink_free(&mut self, block: u32) {
        let b = block as usize;
        let (prev, next) = (self.prev[b], self.next[b]);
        if prev != NONE {
            self.next[prev as usize] = next;
        } else {
            self.heads[self.order[b] as usize] = next;
        }
        if next != NONE {
            self.prev[next as usize] = prev;
        }
    }

    /// Smallest order whose block holds `len` bytes, or None if no block can.
    pub fn order_for(&self, len: usize) -> Option<usize> {
        let want = len.max(self.min_block);
        if want > self.bytes.len() {
            return None;
        }
        Some((want.next_power_of_two() / self.min_block).trailing_zeros() as usize)
    }

    /// Returns the minimum-block number of a block of order k, or None if the heap has
    /// no free block that large (even if the total free space would suffice: that is
    /// external fragmentation).
    pub fn alloc_block(&mut self, k: usize) -> Option<u32> {
        let mut j = (k..=self.max_order).find(|&j| self.heads[j] != NONE)?;
        let block = self.heads[j];
        self.unlink_free(block);
        // Split down to the wanted order. The left half is kept, the right half (the
        // buddy) becomes a free block one order lower.
        while j > k {
            j -= 1;
            self.push_free(block + (1 << j), j);
        }
        self.state[block as usize] = State::Used;
        self.order[block as usize] = k as u8;
        Some(block)
    }

    pub fn free_block(&mut self, start: u32) {
        assert!(
            self.state[start as usize] == State::Used,
            "double free or a pointer into a block"
        );
        let mut block = start;
        let mut k = self.order[block as usize] as usize;
        self.state[block as usize] = State::Inside;
        while k < self.max_order {
            // The buddy is the other half of the parent block: flip bit k.
            let buddy = block ^ (1 << k);
            // Merge only with a buddy that is free AND whole (same order); a buddy
            // that has been split further is partly in use.
            if self.state[buddy as usize] != State::Free || self.order[buddy as usize] as usize != k
            {
                break;
            }
            self.unlink_free(buddy);
            self.state[buddy as usize] = State::Inside;
            block = block.min(buddy);
            k += 1;
        }
        self.push_free(block, k);
    }

    /// Allocate `len` bytes; returns the byte offset of the block.
    pub fn alloc(&mut self, len: usize) -> Option<usize> {
        let k = self.order_for(len)?;
        let block = self.alloc_block(k)?;
        self.lens[block as usize] = len;
        self.requested += len;
        self.granted += self.block_size(k);
        Some(block as usize * self.min_block)
    }

    pub fn free(&mut self, offset: usize) {
        assert!(offset.is_multiple_of(self.min_block), "not a block start");
        let block = offset / self.min_block;
        self.requested -= self.lens[block];
        self.granted -= self.block_size(self.order[block] as usize);
        self.free_block(block as u32);
    }

    /// The bytes of the allocation at `offset` (the offset-to-slice step that replaces
    /// a pointer dereference).
    #[cfg_attr(not(test), allow(dead_code))] // the demo prints maps, the tests write bytes
    pub fn bytes_mut(&mut self, offset: usize) -> &mut [u8] {
        let block = offset / self.min_block;
        assert!(self.state[block] == State::Used);
        &mut self.bytes[offset..offset + self.lens[block]]
    }

    fn free_list(&self, k: usize) -> impl Iterator<Item = u32> + '_ {
        let link = |b: u32| (b != NONE).then_some(b);
        std::iter::successors(link(self.heads[k]), move |&b| link(self.next[b as usize]))
    }

    pub fn free_bytes(&self) -> usize {
        (0..=self.max_order)
            .map(|k| self.free_list(k).count() * self.block_size(k))
            .sum()
    }

    /// Size of the largest request that can succeed right now.
    pub fn largest_free(&self) -> usize {
        (0..=self.max_order)
            .rev()
            .find(|&k| self.heads[k] != NONE)
            .map_or(0, |k| self.block_size(k))
    }

    /// The heap as a row of blocks in address order: `[128 used][128 free][256 free]`.
    pub fn map(&self) -> String {
        let mut out = String::new();
        let mut block = 0;
        while block < self.state.len() {
            let k = self.order[block] as usize;
            let word = if self.state[block] == State::Free {
                "free"
            } else {
                "used"
            };
            out.push_str(&format!("[{} {}]", self.block_size(k), word));
            block += 1 << k;
        }
        out
    }

    /// Blocks tile the heap exactly, free lists and states agree, and no two free
    /// buddies of the same order exist (they would have been merged).
    pub fn validate(&self) -> Result<(), Invalid> {
        let leaf_count = self.state.len();
        let (mut block, mut free_blocks) = (0usize, 0usize);
        while block < leaf_count {
            let k = self.order[block] as usize;
            if self.state[block] == State::Inside || k > self.max_order {
                return Err(Invalid);
            }
            let size = 1usize << k;
            if !block.is_multiple_of(size)
                || self.state[block + 1..block + size]
                    .iter()
                    .any(|&s| s != State::Inside)
            {
                return Err(Invalid);
            }
            if self.state[block] == State::Free {
                free_blocks += 1;
                let buddy = block ^ size;
                if k < self.max_order
                    && self.state[buddy] == State::Free
                    && self.order[buddy] as usize == k
                {
                    return Err(Invalid);
                }
            }
            block += size;
        }
        let mut listed = 0;
        for k in 0..=self.max_order {
            for b in self.free_list(k) {
                if self.state[b as usize] != State::Free || self.order[b as usize] as usize != k {
                    return Err(Invalid);
                }
                listed += 1;
            }
        }
        if block == leaf_count && listed == free_blocks {
            Ok(())
        } else {
            Err(Invalid)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::prng::SplitMix64;

    fn expect_heap(b: &Buddy, expected: &str) {
        assert_eq!(b.map(), expected);
        b.validate().unwrap();
    }

    #[test]
    fn split_on_alloc_merge_on_free() {
        let mut b = Buddy::new(10, 6); // 1024-byte heap, 64-byte minimum block
        expect_heap(&b, "[1024 free]");

        let x = b.alloc(100).unwrap(); // 100 -> 128 bytes
        assert_eq!(x, 0);
        expect_heap(&b, "[128 used][128 free][256 free][512 free]");
        let y = b.alloc(60).unwrap(); // 64: splits the free 128
        expect_heap(&b, "[128 used][64 used][64 free][256 free][512 free]");
        let z = b.alloc(200).unwrap(); // 256: exact fit
        expect_heap(&b, "[128 used][64 used][64 free][256 used][512 free]");

        b.free(x); // buddy [64 used][64 free] is split: no merge
        expect_heap(&b, "[128 free][64 used][64 free][256 used][512 free]");
        b.free(y); // 64+64 -> 128, 128+128 -> 256, then the 256 buddy is used: stop
        expect_heap(&b, "[256 free][256 used][512 free]");
        b.free(z); // cascades to the whole heap
        expect_heap(&b, "[1024 free]");
    }

    #[test]
    fn external_fragmentation_enough_bytes_no_block() {
        let mut b = Buddy::new(10, 6);
        let blocks: Vec<u32> = (0..16).map(|_| b.alloc_block(0).unwrap()).collect();
        assert_eq!(b.alloc_block(0), None);
        for i in 0..8 {
            b.free_block(blocks[i * 2]); // free every other 64-byte block
        }
        assert_eq!(b.free_bytes(), 512);
        assert_eq!(b.largest_free(), 64); // no two free blocks are buddies
        assert_eq!(b.alloc_block(1), None);
        b.validate().unwrap();
        for i in 0..8 {
            b.free_block(blocks[i * 2 + 1]);
        }
        assert_eq!(b.largest_free(), 1024);
    }

    #[test]
    fn offsets_rounding_and_limits() {
        let mut b = Buddy::new(12, 4);
        let page = b.alloc(100).unwrap();
        assert_eq!(b.granted - b.requested, 28); // 100 bytes in a 128 block
        b.bytes_mut(page).fill(7);
        assert_eq!(b.bytes_mut(page).len(), 100);
        assert_eq!(b.alloc(8192), None);
        assert_eq!(b.order_for(4096), Some(8));
        b.free(page);
        b.validate().unwrap();
        assert_eq!(b.largest_free(), 4096); // fully coalesced
        assert_eq!(b.requested + b.granted, 0);
    }

    #[test]
    fn random_alloc_free_against_a_shadow_list() {
        let mut b = Buddy::new(12, 4);
        let mut rng = SplitMix64::new(7);
        let mut live: Vec<(usize, u8)> = Vec::new(); // (offset, stamp)
        for step in 0..5000u32 {
            if live.len() < 64 && rng.chance(3, 5) {
                let len = rng.range(1, 300) as usize;
                let Some(offset) = b.alloc(len) else { continue };
                // Stamp the block; an overlap with another live block would corrupt a stamp.
                b.bytes_mut(offset).fill(step as u8);
                live.push((offset, step as u8));
            } else if !live.is_empty() {
                let (offset, stamp) = live.swap_remove(rng.below(live.len() as u64) as usize);
                assert!(b.bytes_mut(offset).iter().all(|&byte| byte == stamp));
                b.free(offset);
            }
            if step % 64 == 0 {
                b.validate().unwrap();
            }
        }
        for (offset, _) in live {
            b.free(offset);
        }
        b.validate().unwrap();
        assert_eq!(b.largest_free(), 4096);
    }
}
