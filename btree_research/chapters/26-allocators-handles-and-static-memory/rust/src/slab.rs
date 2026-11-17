//! A bitmap slab allocator addressed by 32-bit handles (twin of zig/src/slab.zig).
//!
//! Modelled on DuckDB's `FixedSizeAllocator`: memory is cut into slabs, a slab is a
//! bitmap plus equally sized slots, and the tree stores `(slab id, slot)` handles in
//! place of pointers. As in DuckDB, a SET bit means the slot is FREE.
//!
//! Rust has no stable allocator interface to plug this under, and it does not need
//! one: the pool is an ordinary owning container and the handle is the idiom that
//! replaces `*mut Node`. The Zig "backing allocator may fail" is mirrored by a slab
//! `budget`; `freeze` sets it to zero, which is the freeze-after-init policy.

use std::fmt;

/// What the tree stores where a pointer-based tree stores a pointer.
/// Bits 0..8 slot, bits 8..31 slab id, bit 31 size class. All ones = none.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub struct Handle(u32);

impl Handle {
    pub const NONE: Handle = Handle(0xFFFF_FFFF);

    pub fn new(class: u32, slab: u32, slot: u32) -> Handle {
        debug_assert!(class < 2 && slab < (1 << 23) - 1 && slot < 256);
        Handle(class << 31 | slab << 8 | slot)
    }
    pub fn is_none(self) -> bool {
        self == Handle::NONE
    }
    pub fn slot(self) -> usize {
        (self.0 & 0xFF) as usize
    }
    pub fn slab(self) -> usize {
        ((self.0 >> 8) & 0x7F_FFFF) as usize
    }
    /// Size class: which pool the handle belongs to. Checked on every dereference.
    pub fn class(self) -> u32 {
        self.0 >> 31
    }
    pub fn to_int(self) -> u32 {
        self.0
    }
}

/// Printed as `L2.5` / `I0.1`: class letter, slab id, slot.
impl fmt::Display for Handle {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        if self.is_none() {
            return write!(f, "none");
        }
        let letter = if self.class() == 0 { 'L' } else { 'I' };
        write!(f, "{}{}.{}", letter, self.slab(), self.slot())
    }
}

/// The Rust face of `error.OutOfMemory`: the pool may not create another slab.
#[derive(Debug, PartialEq, Eq, Clone, Copy)]
pub struct OutOfNodes;

/// One slab: a bitmap and `S` slots. No per-item header.
struct Slab<T> {
    /// Bit i set <=> slot i is free.
    free: Vec<u64>,
    used: usize,
    items: Vec<T>,
}

pub struct SlabPool<T: Copy, const S: usize> {
    class: u32,
    /// true: DuckDB style, an empty slab is dropped. false: TigerBeetle `NodePool`
    /// style, memory is never given back.
    release_empty: bool,
    /// Slots must hold something even while free; this is the filler.
    blank: T,
    /// Slab id -> slab. A released slab leaves `None`; its id is reused.
    slabs: Vec<Option<Slab<T>>>,
    pub slab_count: u32,
    /// Number of live items over all slabs.
    pub live: u32,
    /// Invariant: no slab with id < hint has a free slot.
    hint: usize,
    /// During `vacuum_begin .. vacuum_end`: the slab being evacuated.
    victim: Option<usize>,
    /// How many more slabs may be created (the stand-in for a fallible allocator).
    pub budget: u32,
    /// How often `create` failed because the budget was exhausted.
    pub grow_failures: u32,
}

impl<T: Copy, const S: usize> SlabPool<T, S> {
    pub fn new(class: u32, release_empty: bool, blank: T) -> Self {
        const { assert!(S >= 1 && S <= 256) };
        SlabPool {
            class,
            release_empty,
            blank,
            slabs: Vec::new(),
            slab_count: 0,
            live: 0,
            hint: 0,
            victim: None,
            budget: u32::MAX,
            grow_failures: 0,
        }
    }

    /// Create slabs until at least `count` exist.
    pub fn reserve(&mut self, count: u32) -> Result<(), OutOfNodes> {
        while self.slab_count < count {
            self.add_slab()?;
        }
        Ok(())
    }

    /// Freeze after init: from now on the pool never grows.
    pub fn freeze(&mut self) {
        self.budget = 0;
    }

    pub fn free_slots(&self) -> u32 {
        self.slab_count * S as u32 - self.live
    }

    fn add_slab(&mut self) -> Result<usize, OutOfNodes> {
        if self.budget == 0 {
            return Err(OutOfNodes);
        }
        self.budget -= 1;
        let mut free = vec![0u64; S.div_ceil(64)];
        for i in 0..S {
            free[i / 64] |= 1 << (i % 64);
        }
        let slab = Slab {
            free,
            used: 0,
            items: vec![self.blank; S],
        };
        // Reuse the lowest released id, so ids (and therefore handles) stay small.
        let id = match self.slabs.iter().position(Option::is_none) {
            Some(id) => {
                self.slabs[id] = Some(slab);
                id
            }
            None => {
                self.slabs.push(Some(slab));
                self.slabs.len() - 1
            }
        };
        self.slab_count += 1;
        self.hint = self.hint.min(id);
        Ok(id)
    }

    fn has_space(&self, id: usize) -> bool {
        self.victim != Some(id) && self.slabs[id].as_ref().is_some_and(|slab| slab.used < S)
    }

    /// Allocate one slot: the lowest free slot of the lowest slab that has one.
    /// The slot keeps whatever it held before, like Zig's undefined memory.
    pub fn create(&mut self) -> Result<Handle, OutOfNodes> {
        let mut id = self.hint;
        while id < self.slabs.len() && !self.has_space(id) {
            id += 1;
        }
        if id == self.slabs.len() {
            id = self.add_slab().inspect_err(|_| self.grow_failures += 1)?;
        }
        if self.victim.is_none() {
            self.hint = id;
        }
        let slab = self.slabs[id].as_mut().expect("has_space checked");
        let word = slab
            .free
            .iter()
            .position(|&w| w != 0)
            .expect("has_space checked");
        // Lowest set bit = lowest free slot.
        let bit = slab.free[word].trailing_zeros() as usize;
        slab.free[word] &= !(1 << bit);
        slab.used += 1;
        self.live += 1;
        Ok(Handle::new(self.class, id as u32, (word * 64 + bit) as u32))
    }

    pub fn is_live(&self, h: Handle) -> bool {
        if h.is_none() || h.class() != self.class || h.slab() >= self.slabs.len() || h.slot() >= S {
            return false;
        }
        match &self.slabs[h.slab()] {
            Some(slab) => slab.free[h.slot() / 64] & (1 << (h.slot() % 64)) == 0,
            None => false,
        }
    }

    /// Handle -> reference: one directory load plus an index.
    pub fn get(&self, h: Handle) -> &T {
        assert!(self.is_live(h), "stale handle {h}");
        &self.slabs[h.slab()].as_ref().expect("live").items[h.slot()]
    }

    pub fn get_mut(&mut self, h: Handle) -> &mut T {
        assert!(self.is_live(h), "stale handle {h}");
        &mut self.slabs[h.slab()].as_mut().expect("live").items[h.slot()]
    }

    pub fn destroy(&mut self, h: Handle) {
        assert!(self.is_live(h), "stale handle {h}");
        let id = h.slab();
        let slab = self.slabs[id].as_mut().expect("live");
        slab.free[h.slot() / 64] |= 1 << (h.slot() % 64);
        slab.used -= 1;
        let now_empty = slab.used == 0;
        self.live -= 1;
        if self.victim != Some(id) {
            self.hint = self.hint.min(id);
        }
        if !now_empty || !self.release_empty {
            return;
        }
        // Keep the slab if it is the only place the next `create` could go; otherwise
        // a create/destroy pair at a slab boundary would allocate a slab each time.
        let other_space = self.victim == Some(id)
            || (0..self.slabs.len()).any(|other| other != id && self.has_space(other));
        if other_space {
            self.slabs[id] = None;
            self.slab_count -= 1;
        }
    }

    // ---- vacuum: evacuate the emptiest slab so it can be released --------------------

    /// Picks a victim if a whole slab's worth of slots is free elsewhere. The owner of
    /// the handles must then `relocate` every item of the victim and call `vacuum_end`.
    pub fn vacuum_begin(&mut self) -> bool {
        assert!(self.victim.is_none() && self.release_empty);
        if self.slab_count < 2 || self.free_slots() < S as u32 {
            return false;
        }
        let mut best: Option<(usize, usize)> = None; // (id, used)
        for (id, slab) in self.slabs.iter().enumerate() {
            let Some(slab) = slab else { continue };
            // `<=`: among equally empty slabs take the highest id.
            if best.is_none_or(|(_, used)| slab.used <= used) {
                best = Some((id, slab.used));
            }
        }
        self.victim = best.map(|(id, _)| id);
        self.hint = 0;
        true
    }

    pub fn is_victim(&self, h: Handle) -> bool {
        self.victim == Some(h.slab())
    }

    /// Move one item out of the victim slab and return its new handle. Cannot fail:
    /// `vacuum_begin` checked that the other slabs have room.
    pub fn relocate(&mut self, old: Handle) -> Handle {
        assert!(self.is_victim(old));
        let value = *self.get(old);
        let new = self.create().expect("vacuum_begin guaranteed room");
        *self.get_mut(new) = value;
        self.destroy(old); // releases the victim slab when its last item leaves
        new
    }

    pub fn vacuum_end(&mut self) {
        let id = self.victim.take().expect("vacuum in progress");
        if let Some(slab) = &self.slabs[id] {
            // Only possible if the victim was the kept empty slab.
            assert!(slab.used == 0, "an item of the victim was not relocated");
            self.slabs[id] = None;
            self.slab_count -= 1;
        }
        self.hint = 0;
    }

    /// One line per pool, for the demo and the visualization: `0[##.#] 1[#...]`.
    pub fn map(&self) -> String {
        if self.slabs.is_empty() {
            return "(no slabs)".to_string();
        }
        let mut parts = Vec::new();
        for (id, slab) in self.slabs.iter().enumerate() {
            match slab {
                None => parts.push(format!("{id}[released]")),
                Some(slab) => {
                    let cells: String = (0..S)
                        .map(|i| {
                            if slab.free[i / 64] & (1 << (i % 64)) != 0 {
                                '.'
                            } else {
                                '#'
                            }
                        })
                        .collect();
                    parts.push(format!("{id}[{cells}]"));
                }
            }
        }
        parts.join(" ")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn handle_is_32_bits_slot_slab_class() {
        assert_eq!(std::mem::size_of::<Handle>(), 4);
        let h = Handle::new(1, 2, 5);
        assert_eq!(h.to_int(), 0x8000_0205);
        assert!(Handle::NONE.is_none() && !h.is_none());
        assert_eq!(h.to_string(), "I2.5");
    }

    #[test]
    fn slots_fill_in_order_and_the_lowest_hole_is_reused_first() {
        let mut pool: SlabPool<u64, 4> = SlabPool::new(0, true, 0);
        let hs: Vec<Handle> = (0..6)
            .map(|i| {
                let h = pool.create().unwrap();
                *pool.get_mut(h) = i * 100;
                h
            })
            .collect();
        assert_eq!(pool.map(), "0[####] 1[##..]");
        assert_eq!(hs[5], Handle::new(0, 1, 1));

        pool.destroy(hs[3]);
        pool.destroy(hs[1]);
        assert_eq!(pool.map(), "0[#.#.] 1[##..]");
        assert!(!pool.is_live(hs[1]));
        assert_eq!(pool.create().unwrap(), hs[1]); // lowest slab, lowest slot
        assert_eq!(*pool.get(hs[2]), 200); // neighbours untouched
        assert_eq!(pool.live, 5);
        assert_eq!(pool.free_slots(), 3);
    }

    #[test]
    fn an_empty_slab_is_released_but_not_the_last_one_with_free_space() {
        let mut pool: SlabPool<u64, 2> = SlabPool::new(0, true, 0);
        let hs: Vec<Handle> = (0..5).map(|_| pool.create().unwrap()).collect();
        assert_eq!(pool.map(), "0[##] 1[##] 2[#.]");
        pool.destroy(hs[2]);
        pool.destroy(hs[3]); // slab 1 empty, slab 2 still has space: release slab 1
        assert_eq!(pool.map(), "0[##] 1[released] 2[#.]");
        pool.destroy(hs[4]); // slab 2 empty and the only one with space: keep it
        assert_eq!(pool.map(), "0[##] 1[released] 2[..]");
        pool.destroy(hs[0]);
        pool.destroy(hs[1]); // slab 0 empty, slab 2 has space: release slab 0
        assert_eq!(pool.map(), "0[released] 1[released] 2[..]");
        assert_eq!(pool.slab_count, 1);
        // A released id is reused before the directory grows.
        pool.create().unwrap();
        pool.create().unwrap();
        assert_eq!(pool.create().unwrap().slab(), 0);
        assert_eq!(pool.map(), "0[#.] 1[released] 2[##]");
    }

    #[test]
    fn a_bitmap_longer_than_one_word() {
        let mut pool: SlabPool<u8, 100> = SlabPool::new(0, true, 0);
        for i in 0..130 {
            let h = pool.create().unwrap();
            assert_eq!((h.slab(), h.slot()), (i / 100, i % 100));
        }
        assert_eq!(pool.free_slots(), 70);
    }

    #[test]
    fn static_policy_reserve_then_no_growth_and_no_release() {
        let mut pool: SlabPool<u64, 2> = SlabPool::new(0, false, 0);
        pool.reserve(2).unwrap();
        pool.freeze();
        let hs: Vec<Handle> = (0..4).map(|_| pool.create().unwrap()).collect();
        assert_eq!(pool.create(), Err(OutOfNodes));
        assert_eq!(pool.grow_failures, 1);
        for h in hs {
            pool.destroy(h);
        }
        assert_eq!(pool.map(), "0[..] 1[..]"); // nothing was given back
    }

    #[test]
    fn create_under_every_budget() {
        // The analogue of checkAllAllocationFailures: fail the 1st, 2nd, ... slab.
        for budget in 0..4 {
            let mut pool: SlabPool<u64, 2> = SlabPool::new(0, true, 0);
            pool.budget = budget;
            let created = (0..7).take_while(|_| pool.create().is_ok()).count();
            assert_eq!(created as u32, (budget * 2).min(7));
            assert_eq!(pool.live, created as u32);
        }
    }

    #[test]
    fn vacuum_evacuates_the_emptiest_slab() {
        let mut pool: SlabPool<u64, 4> = SlabPool::new(0, true, 0);
        let mut hs: Vec<Handle> = (0..12)
            .map(|i| {
                let h = pool.create().unwrap();
                *pool.get_mut(h) = i;
                h
            })
            .collect();
        assert!(!pool.vacuum_begin()); // full: nothing to gain
        for i in [1, 2, 4, 5, 6, 9] {
            pool.destroy(hs[i]);
        }
        assert_eq!(pool.map(), "0[#..#] 1[...#] 2[#.##]");

        assert!(pool.vacuum_begin());
        assert!(pool.is_victim(hs[7]) && !pool.is_victim(hs[0]));
        hs[7] = pool.relocate(hs[7]);
        pool.vacuum_end();
        assert_eq!(pool.map(), "0[##.#] 1[released] 2[#.##]");
        assert_eq!(*pool.get(hs[7]), 7); // same value, new handle
        assert_eq!(hs[7], Handle::new(0, 0, 1));
    }

    #[test]
    #[should_panic(expected = "stale handle L0.0")]
    fn a_stale_handle_is_caught() {
        let mut pool: SlabPool<u64, 4> = SlabPool::new(0, true, 0);
        let h = pool.create().unwrap();
        pool.destroy(h);
        pool.get(h);
    }
}
