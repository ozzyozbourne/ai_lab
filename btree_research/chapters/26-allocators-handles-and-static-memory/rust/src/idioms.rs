//! The Rust counterpart of the Zig allocator tour (zig/src/tour.zig).
//!
//! Zig's std offers a dozen allocators behind one interface. Rust's `Allocator` trait
//! is unstable, so in stable Rust the same goals are reached with small owning
//! containers and integer handles. Four idioms, each a tested example, each with the
//! place a B-tree engine would use it. (`slab.rs` and `buddy.rs` are two more.)

/// Idiom 1: typed arena: `Vec<T>` plus `u32` ids. Nothing is freed one by one; dropping
/// the arena frees everything. Zig twin: `ArenaAllocator`. Engine use: a bulk-loaded,
/// read-only tree, or the nodes of one query plan.
pub struct TypedArena<T> {
    items: Vec<T>,
}

impl<T> TypedArena<T> {
    pub fn new() -> Self {
        TypedArena { items: Vec::new() }
    }
    pub fn alloc(&mut self, value: T) -> u32 {
        self.items.push(value);
        (self.items.len() - 1) as u32
    }
    pub fn get(&self, id: u32) -> &T {
        &self.items[id as usize]
    }
    pub fn get_mut(&mut self, id: u32) -> &mut T {
        &mut self.items[id as usize]
    }
    /// Forget everything but keep the memory (Zig: `arena.reset(.retain_capacity)`).
    pub fn reset(&mut self) {
        self.items.clear();
    }
}

/// Idiom 2: slab with a free list and generation-checked handles. Freed slots are chained
/// through the slab itself (Zig twin: `MemoryPool`); each slot also counts how often
/// it was freed, and a handle remembers the count it was created under. A handle to
/// a freed-and-reused slot is then DETECTED, where a raw pointer (and the plain
/// bitmap slab of this chapter) would silently read the new occupant.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub struct GenHandle {
    index: u32,
    generation: u32,
}

enum Slot<T> {
    Used {
        generation: u32,
        value: T,
    },
    Free {
        generation: u32,
        next_free: Option<u32>,
    },
}

pub struct GenSlab<T> {
    slots: Vec<Slot<T>>,
    free_head: Option<u32>,
    len: usize,
}

impl<T> GenSlab<T> {
    pub fn new() -> Self {
        GenSlab {
            slots: Vec::new(),
            free_head: None,
            len: 0,
        }
    }

    pub fn len(&self) -> usize {
        self.len
    }

    pub fn insert(&mut self, value: T) -> GenHandle {
        self.len += 1;
        match self.free_head {
            Some(index) => {
                let Slot::Free {
                    generation,
                    next_free,
                } = self.slots[index as usize]
                else {
                    unreachable!("free list points at a used slot")
                };
                self.free_head = next_free;
                self.slots[index as usize] = Slot::Used { generation, value };
                GenHandle { index, generation }
            }
            None => {
                self.slots.push(Slot::Used {
                    generation: 0,
                    value,
                });
                GenHandle {
                    index: (self.slots.len() - 1) as u32,
                    generation: 0,
                }
            }
        }
    }

    /// `None` for a handle whose slot was freed (and perhaps reused) since.
    pub fn get(&self, h: GenHandle) -> Option<&T> {
        match self.slots.get(h.index as usize)? {
            Slot::Used { generation, value } if *generation == h.generation => Some(value),
            _ => None,
        }
    }

    pub fn remove(&mut self, h: GenHandle) -> Option<T> {
        self.get(h)?;
        // Bump the generation: every outstanding handle to this slot is now stale.
        let freed = Slot::Free {
            generation: h.generation + 1,
            next_free: self.free_head,
        };
        let Slot::Used { value, .. } = std::mem::replace(&mut self.slots[h.index as usize], freed)
        else {
            unreachable!("get() said the slot is used")
        };
        self.free_head = Some(h.index);
        self.len -= 1;
        Some(value)
    }
}

/// Idiom 3: bump arena of bytes: a `Vec<u8>` with a fixed capacity; allocation moves an
/// offset, nothing is freed individually. Zig twin: `FixedBufferAllocator`. Engine use:
/// variable-length keys of one node or one operation, referenced by `(offset, len)`.
pub struct Bump {
    bytes: Vec<u8>,
    capacity: usize,
}

impl Bump {
    pub fn with_capacity(capacity: usize) -> Self {
        Bump {
            bytes: Vec::with_capacity(capacity),
            capacity,
        }
    }
    /// Copies `data` in and returns its offset, or `None` when the arena is full.
    pub fn push(&mut self, data: &[u8]) -> Option<u32> {
        if self.bytes.len() + data.len() > self.capacity {
            return None;
        }
        let offset = self.bytes.len() as u32;
        self.bytes.extend_from_slice(data);
        Some(offset)
    }
    pub fn get(&self, offset: u32, len: usize) -> &[u8] {
        &self.bytes[offset as usize..offset as usize + len]
    }
    pub fn reset(&mut self) {
        self.bytes.clear();
    }
}

/// Idiom 4: fixed-capacity pool: all memory is taken up front, `acquire` fails when the
/// pool is empty, `release` makes the slot available again. Zig twins: non-growable
/// `MemoryPool`, TigerBeetle's `NodePool`. Engine use: buffer-pool frames.
pub struct FixedPool<T> {
    items: Vec<T>,
    free: Vec<u32>,
}

impl<T: Clone> FixedPool<T> {
    pub fn new(capacity: u32, blank: T) -> Self {
        // Reversed so that slot 0 is handed out first.
        FixedPool {
            items: vec![blank; capacity as usize],
            free: (0..capacity).rev().collect(),
        }
    }
    pub fn acquire(&mut self) -> Option<u32> {
        self.free.pop()
    }
    pub fn release(&mut self, id: u32) {
        debug_assert!(!self.free.contains(&id), "double release");
        self.free.push(id);
    }
    pub fn get_mut(&mut self, id: u32) -> &mut T {
        &mut self.items[id as usize]
    }
    pub fn available(&self) -> usize {
        self.free.len()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn typed_arena_build_many_free_once() {
        struct Node {
            key: u64,
            next: Option<u32>,
        }
        let mut arena = TypedArena::new();
        let mut head = None;
        for key in 0..100 {
            head = Some(arena.alloc(Node { key, next: head }));
        }
        let mut sum = 0;
        let mut cursor = head;
        while let Some(id) = cursor {
            sum += arena.get(id).key;
            cursor = arena.get(id).next;
        }
        assert_eq!(sum, 4950);
        arena.get_mut(0).key = 7;
        arena.reset(); // every id is invalid now; the memory is kept for the next batch
        assert_eq!(arena.alloc(Node { key: 1, next: None }), 0);
    } // drop frees all nodes at once

    #[test]
    fn gen_slab_detects_a_stale_handle() {
        let mut slab = GenSlab::new();
        let a = slab.insert("a");
        let b = slab.insert("b");
        assert_eq!(slab.remove(a), Some("a"));
        let c = slab.insert("c"); // reuses a's slot ...
        assert_eq!(c.index, a.index);
        assert_eq!(slab.get(c), Some(&"c"));
        assert_eq!(slab.get(a), None); // ... but the old handle no longer opens it
        assert_eq!(slab.remove(a), None); // and a double free is harmless
        assert_eq!(slab.get(b), Some(&"b"));
        assert_eq!(slab.len(), 2);
    }

    #[test]
    fn bump_bounded_scratch() {
        let mut bump = Bump::with_capacity(16);
        let a = bump.push(b"user:42").unwrap();
        let b = bump.push(b"user:43").unwrap();
        assert_eq!((a, b), (0, 7));
        assert_eq!(bump.get(b, 7), b"user:43");
        assert_eq!(bump.push(b"too long"), None); // bound enforced, nothing reallocated
        bump.reset();
        assert_eq!(bump.push(b"x"), Some(0));
    }

    #[test]
    fn fixed_pool_never_grows() {
        let mut frames = FixedPool::new(2, [0u8; 64]);
        let a = frames.acquire().unwrap();
        let b = frames.acquire().unwrap();
        assert_eq!((a, b), (0, 1));
        assert_eq!(frames.acquire(), None); // every frame is in use
        frames.get_mut(a)[0] = 1;
        frames.release(a); // "evict" one frame ...
        assert_eq!(frames.acquire(), Some(a)); // ... and it is available again
        assert_eq!(frames.available(), 0);
    }
}
