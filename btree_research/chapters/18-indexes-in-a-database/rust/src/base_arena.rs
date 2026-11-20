// Copied from chapters/07-bplus-trees/rust/src/arena.rs; only the module paths were renamed to base_*.
//! Index arena: every node of the tree lives in ONE `Vec` and is named by a
//! 32-bit handle (`NodeId`), never by a reference or a `Box`.
//!
//! Why handles instead of `Box<Node>` / `Rc<RefCell<Node>>`:
//!   * a handle is 4 bytes (a pointer is 8), so internal nodes get denser;
//!   * a handle is `Copy` and borrows nothing, so sibling links and "the left
//!     neighbour's `next` field" do not fight the borrow checker;
//!   * a handle is exactly what an on-disk tree stores (a page number), so the
//!     code in this chapter keeps its shape when nodes become pages (chapter 12);
//!   * the whole tree is freed by dropping one `Vec`.
//!
//! Freed slots are threaded onto a free list (each free slot stores the id of
//! the next free slot) and are reused last-in-first-out, so the `Vec` never
//! has to shrink and `alloc` / `free` are O(1).
//!
//! Zig's version can fail with `error.OutOfMemory` when the array grows. A
//! Rust `Vec` aborts instead, so the same failure is modelled with a node
//! budget: `reserve` returns `Err(OutOfNodes)` when the arena would exceed
//! `max_nodes` live nodes.

/// Handle of a node: an index into the arena. `NodeId::NIL` plays the role of
/// a null pointer (or of "page 0 = no page" in an on-disk format).
///
/// A newtype instead of a bare `u32` so that the compiler refuses to mix
/// handles up with key counts and array indices.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct NodeId(u32);

impl NodeId {
    pub const NIL: NodeId = NodeId(u32::MAX);

    pub fn is_nil(self) -> bool {
        self == NodeId::NIL
    }

    /// Position in the arena's slot array. Never call on `NIL`.
    pub fn index(self) -> usize {
        assert!(!self.is_nil(), "NIL handle dereferenced");
        self.0 as usize
    }

    pub fn from_index(i: usize) -> NodeId {
        let raw = u32::try_from(i).expect("arena full");
        assert!(raw != u32::MAX, "arena full"); // u32::MAX is reserved for NIL
        NodeId(raw)
    }
}

/// `reserve` was asked for more nodes than the budget allows.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct OutOfNodes;

impl std::fmt::Display for OutOfNodes {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("node budget exhausted")
    }
}

impl std::error::Error for OutOfNodes {}

/// A slot either holds a live value or is a link of the free list. The tag
/// is what lets `free` catch a double free and `validate` catch a handle that
/// points at a freed node.
#[derive(Debug)]
enum Slot<T> {
    Used(T),
    Free(NodeId), // next free slot, or NIL
}

#[derive(Debug)]
pub struct Arena<T> {
    slots: Vec<Slot<T>>,
    /// Most recently freed slot (head of the free list), or NIL.
    free_head: NodeId,
    /// Number of `Used` slots.
    live: usize,
    /// Most live nodes allowed; `usize::MAX` for "no limit".
    max_nodes: usize,
}

impl<T> Default for Arena<T> {
    fn default() -> Self {
        Self::new()
    }
}

impl<T> Arena<T> {
    pub fn new() -> Self {
        Self::with_budget(usize::MAX)
    }

    /// An arena that refuses to hold more than `max_nodes` live nodes.
    pub fn with_budget(max_nodes: usize) -> Self {
        Self {
            slots: Vec::new(),
            free_head: NodeId::NIL,
            live: 0,
            max_nodes,
        }
    }

    /// Makes sure the next `n` calls to `alloc_reserved` are within budget.
    /// The only function that can fail.
    pub fn reserve(&mut self, n: usize) -> Result<(), OutOfNodes> {
        if n > self.max_nodes.saturating_sub(self.live) {
            return Err(OutOfNodes);
        }
        let free_slots = self.slots.len() - self.live;
        self.slots.reserve(n.saturating_sub(free_slots));
        Ok(())
    }

    pub fn alloc(&mut self, value: T) -> Result<NodeId, OutOfNodes> {
        self.reserve(1)?;
        Ok(self.alloc_reserved(value))
    }

    /// Takes a slot from the free list if there is one, otherwise appends.
    /// Call only after a successful `reserve` that covers it.
    pub fn alloc_reserved(&mut self, value: T) -> NodeId {
        assert!(self.live < self.max_nodes, "alloc_reserved without reserve");
        self.live += 1;
        if !self.free_head.is_nil() {
            let id = self.free_head;
            let Slot::Free(next) = self.slots[id.index()] else {
                unreachable!("free list points at a used slot");
            };
            self.free_head = next; // pop
            self.slots[id.index()] = Slot::Used(value);
            return id;
        }
        let id = NodeId::from_index(self.slots.len());
        self.slots.push(Slot::Used(value));
        id
    }

    /// Returns the slot to the free list. The handle (and every copy of it)
    /// is dangling afterwards; the caller must have unlinked the node.
    pub fn free(&mut self, id: NodeId) {
        let slot = &mut self.slots[id.index()];
        assert!(matches!(slot, Slot::Used(_)), "double free of {id:?}");
        *slot = Slot::Free(self.free_head);
        self.free_head = id;
        self.live -= 1;
    }

    /// Read-only access. Panics on a freed or NIL handle.
    pub fn get(&self, id: NodeId) -> &T {
        match &self.slots[id.index()] {
            Slot::Used(value) => value,
            Slot::Free(_) => panic!("stale handle {id:?}"),
        }
    }

    /// Mutable access. Panics on a freed or NIL handle.
    pub fn get_mut(&mut self, id: NodeId) -> &mut T {
        match &mut self.slots[id.index()] {
            Slot::Used(value) => value,
            Slot::Free(_) => panic!("stale handle {id:?}"),
        }
    }

    /// Two different nodes mutably at once (a node and its sibling during a
    /// split, borrow or merge). Zig simply takes two pointers; Rust needs
    /// `get_disjoint_mut` to prove the two slots do not alias.
    pub fn pair_mut(&mut self, a: NodeId, b: NodeId) -> (&mut T, &mut T) {
        let [x, y] = self
            .slots
            .get_disjoint_mut([a.index(), b.index()])
            .expect("pair_mut needs two different live handles");
        match (x, y) {
            (Slot::Used(x), Slot::Used(y)) => (x, y),
            _ => panic!("stale handle in pair_mut"),
        }
    }

    /// True if `id` names a live node. Used by `validate`, which must not
    /// trust the handles it finds inside nodes.
    pub fn is_live(&self, id: NodeId) -> bool {
        !id.is_nil() && matches!(self.slots.get(id.index()), Some(Slot::Used(_)))
    }

    pub fn live_count(&self) -> usize {
        self.live
    }

    /// Slots ever created (live + free). The arena's high-water mark.
    pub fn slot_count(&self) -> usize {
        self.slots.len()
    }

    /// The free list from its head (most recently freed first). Returns
    /// `None` if the list is corrupt (reaches a used slot, or is longer than
    /// the array, which means a cycle).
    pub fn free_list(&self) -> Option<Vec<NodeId>> {
        let mut list = Vec::new();
        let mut id = self.free_head;
        while !id.is_nil() {
            if list.len() > self.slots.len() {
                return None;
            }
            match self.slots.get(id.index())? {
                Slot::Free(next) => {
                    list.push(id);
                    id = *next;
                }
                Slot::Used(_) => return None,
            }
        }
        Some(list)
    }

    /// Length of the free list, or `None` if it is corrupt.
    pub fn free_count(&self) -> Option<usize> {
        self.free_list().map(|list| list.len())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn alloc_free_reuse_slots_are_recycled_last_in_first_out() {
        let mut arena: Arena<u64> = Arena::new();
        let a = arena.alloc(10).unwrap();
        let b = arena.alloc(20).unwrap();
        let c = arena.alloc(30).unwrap();
        assert_eq!(a.index(), 0);
        assert_eq!(c.index(), 2);
        assert_eq!(arena.live_count(), 3);

        arena.free(a);
        arena.free(c);
        assert!(!arena.is_live(a));
        assert!(arena.is_live(b));
        assert_eq!(arena.free_count(), Some(2));

        // c was freed last, so it is handed out first; the Vec does not grow.
        assert_eq!(arena.alloc(31).unwrap(), c);
        assert_eq!(arena.alloc(11).unwrap(), a);
        assert_eq!(arena.slot_count(), 3);
        assert_eq!(*arena.get(c), 31);
        assert_eq!(*arena.get(b), 20);
        assert!(!arena.is_live(NodeId::NIL));
    }

    #[test]
    fn a_handle_survives_growth_of_the_vec() {
        let mut arena: Arena<u64> = Arena::new();
        let first = arena.alloc(7).unwrap();
        // The borrow checker would reject holding `arena.get(first)` across
        // this loop; in Zig the same mistake compiles and is a use-after-free.
        for i in 0..1000 {
            arena.alloc(i).unwrap();
        }
        assert_eq!(*arena.get(first), 7);
    }

    #[test]
    fn reserve_enforces_the_node_budget() {
        let mut arena: Arena<u64> = Arena::with_budget(3);
        arena.reserve(3).unwrap();
        let a = arena.alloc_reserved(1);
        arena.alloc_reserved(2);
        arena.alloc_reserved(3);
        assert_eq!(arena.reserve(1), Err(OutOfNodes));
        assert_eq!(arena.alloc(4), Err(OutOfNodes));
        arena.free(a);
        // One free slot is enough for one more node.
        arena.reserve(1).unwrap();
        assert_eq!(arena.reserve(2), Err(OutOfNodes));
        assert_eq!(arena.live_count(), 2);
        assert_eq!(arena.free_count(), Some(1));
    }

    #[test]
    fn pair_mut_gives_two_nodes_at_once() {
        let mut arena: Arena<u64> = Arena::new();
        let a = arena.alloc(1).unwrap();
        let b = arena.alloc(2).unwrap();
        let (x, y) = arena.pair_mut(a, b);
        std::mem::swap(x, y);
        assert_eq!((*arena.get(a), *arena.get(b)), (2, 1));
    }

    #[test]
    #[should_panic(expected = "double free")]
    fn double_free_panics() {
        let mut arena: Arena<u64> = Arena::new();
        let id = arena.alloc(1).unwrap();
        arena.free(id);
        arena.free(id);
    }
}
