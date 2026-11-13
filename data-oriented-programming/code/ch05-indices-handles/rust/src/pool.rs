//! A generational pool (a "slot map"): values live in one Vec of slots, callers hold
//! 8-byte `Handle<T>`s (index + generation), and a free list is threaded through the
//! free slots themselves. Std only, no `unsafe`.

use std::marker::PhantomData;
use std::num::NonZeroU32;

/// Typed handle: 8 bytes, `Copy`, and `Option<Handle<T>>` is still 8 bytes, because a
/// `NonZeroU32` generation leaves the value 0 free for `None` (a "niche").
pub struct Handle<T> {
    index: u32,
    generation: NonZeroU32,
    _marker: PhantomData<fn() -> T>, // typed, but owns no T: Send + Sync + Copy for any T
}

// Written by hand: `#[derive]` would add `T: Copy`, `T: PartialEq`, ... bounds.
impl<T> Clone for Handle<T> {
    fn clone(&self) -> Self {
        *self
    }
}
impl<T> Copy for Handle<T> {}
impl<T> PartialEq for Handle<T> {
    fn eq(&self, o: &Self) -> bool {
        self.index == o.index && self.generation == o.generation
    }
}
impl<T> Eq for Handle<T> {}
impl<T> std::fmt::Debug for Handle<T> {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}v{}", self.index, self.generation)
    }
}

impl<T> Handle<T> {
    pub fn index(self) -> u32 {
        self.index
    }
    pub fn generation(self) -> u32 {
        self.generation.get()
    }
}

/// One slot: either a live value or a link in the free list. The generation lives
/// outside the enum so it survives the slot being freed and reused.
struct Slot<T> {
    generation: NonZeroU32,
    state: State<T>,
}

enum State<T> {
    Occupied(T),
    Free { next_free: Option<u32> },
    Retired, // generation counter exhausted: never handed out again
}

pub struct Pool<T> {
    slots: Vec<Slot<T>>,
    free_head: Option<u32>, // the free list lives *inside* `slots`
    len: usize,
}

impl<T> Default for Pool<T> {
    fn default() -> Self {
        Self::new()
    }
}

impl<T> Pool<T> {
    pub const fn new() -> Self {
        Self { slots: Vec::new(), free_head: None, len: 0 }
    }

    pub fn insert(&mut self, value: T) -> Handle<T> {
        self.len += 1;
        if let Some(index) = self.free_head {
            let slot = &mut self.slots[index as usize];
            let State::Free { next_free } = slot.state else { unreachable!("free list points at a used slot") };
            self.free_head = next_free; // pop the free list
            slot.state = State::Occupied(value);
            return Handle { index, generation: slot.generation, _marker: PhantomData };
        }
        let index = u32::try_from(self.slots.len()).expect("pool full");
        let generation = NonZeroU32::MIN; // 1: a zeroed handle is never valid
        self.slots.push(Slot { generation, state: State::Occupied(value) });
        Handle { index, generation, _marker: PhantomData }
    }

    pub fn remove(&mut self, h: Handle<T>) -> Option<T> {
        let slot = self.slots.get_mut(h.index as usize)?;
        if slot.generation != h.generation || !matches!(slot.state, State::Occupied(_)) {
            return None; // stale or double remove
        }
        // Bump the generation so every outstanding copy of `h` stops matching.
        let state = match slot.generation.checked_add(1) {
            Some(g) => {
                slot.generation = g;
                let s = State::Free { next_free: self.free_head };
                self.free_head = Some(h.index); // push onto the free list
                s
            }
            None => State::Retired, // wrapping would make old handles valid again
        };
        self.len -= 1;
        match std::mem::replace(&mut slot.state, state) {
            State::Occupied(v) => Some(v),
            _ => unreachable!(),
        }
    }

    pub fn get(&self, h: Handle<T>) -> Option<&T> {
        match self.slots.get(h.index as usize)? {
            Slot { generation, state: State::Occupied(v) } if *generation == h.generation => Some(v),
            _ => None,
        }
    }

    pub fn get_mut(&mut self, h: Handle<T>) -> Option<&mut T> {
        match self.slots.get_mut(h.index as usize)? {
            Slot { generation, state: State::Occupied(v) } if *generation == h.generation => Some(v),
            _ => None,
        }
    }

    /// Two `&mut` at once from two distinct live handles: no RefCell, no unsafe.
    /// `get_disjoint_mut` (stable since 1.86) returns Err if the indices overlap.
    pub fn get2_mut(&mut self, a: Handle<T>, b: Handle<T>) -> Option<[&mut T; 2]> {
        let [sa, sb] = self.slots.get_disjoint_mut([a.index as usize, b.index as usize]).ok()?;
        match (sa, sb) {
            (Slot { generation: ga, state: State::Occupied(va) }, Slot { generation: gb, state: State::Occupied(vb) })
                if *ga == a.generation && *gb == b.generation =>
            {
                Some([va, vb])
            }
            _ => None,
        }
    }

    pub fn len(&self) -> usize {
        self.len
    }

    pub fn is_empty(&self) -> bool {
        self.len == 0
    }

    /// Slots ever created (live + free + retired): the array never shrinks.
    pub fn slot_count(&self) -> usize {
        self.slots.len()
    }

    /// Live values with their handles, in slot order (free slots are holes to skip).
    pub fn iter(&self) -> impl Iterator<Item = (Handle<T>, &T)> {
        self.slots.iter().enumerate().filter_map(|(i, s)| match &s.state {
            State::Occupied(v) => Some((Handle { index: i as u32, generation: s.generation, _marker: PhantomData }, v)),
            _ => None,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn handle_is_8_bytes_and_option_is_free() {
        assert_eq!(size_of::<Handle<String>>(), 8);
        assert_eq!(size_of::<Option<Handle<String>>>(), 8);
    }

    #[test]
    fn stale_handle_is_detected_after_reuse() {
        let mut p = Pool::new();
        let a = p.insert("orc");
        let b = p.insert("elf");
        assert_eq!(p.remove(a), Some("orc"));
        assert_eq!(p.get(a), None, "removed handle must not resolve");
        assert_eq!(p.remove(a), None, "double remove must be rejected");
        let c = p.insert("goblin"); // reuses a's slot
        assert_eq!(c.index(), a.index());
        assert_eq!(c.generation(), a.generation() + 1);
        assert_eq!(p.get(a), None, "stale handle must not see the new occupant");
        assert_eq!(p.get(c), Some(&"goblin"));
        assert_eq!(p.get(b), Some(&"elf"));
        assert_eq!(p.len(), 2);
    }

    #[test]
    fn free_list_is_lifo_and_in_array() {
        let mut p = Pool::new();
        let hs: Vec<_> = (0..5).map(|i| p.insert(i)).collect();
        p.remove(hs[1]);
        p.remove(hs[3]);
        assert_eq!(p.insert(30).index(), 3, "last freed slot is reused first");
        assert_eq!(p.insert(10).index(), 1);
        assert_eq!(p.insert(5).index(), 5, "empty free list: append");
        assert_eq!(p.slot_count(), 6);
    }

    #[test]
    fn handles_survive_growth() {
        let mut p = Pool::new();
        let first = p.insert(7u64);
        for i in 0..10_000 {
            p.insert(i); // the Vec reallocates many times; a &u64 would dangle, the handle does not
        }
        assert_eq!(p.get(first), Some(&7));
    }

    #[test]
    fn disjoint_mut_rejects_aliasing() {
        let mut p = Pool::new();
        let a = p.insert(1);
        let b = p.insert(2);
        if let Some([x, y]) = p.get2_mut(a, b) {
            std::mem::swap(x, y);
        }
        assert_eq!((p.get(a), p.get(b)), (Some(&2), Some(&1)));
        assert!(p.get2_mut(a, a).is_none(), "the same slot twice would be two &mut to one value");
    }

    #[test]
    fn iter_skips_holes() {
        let mut p = Pool::new();
        let hs: Vec<_> = (0..4).map(|i| p.insert(i)).collect();
        p.remove(hs[2]);
        let live: Vec<i32> = p.iter().map(|(_, v)| *v).collect();
        assert_eq!(live, [0, 1, 3]);
    }
}
