//! Node arena: `Vec` storage + typed indices + a slab-style free list.
//!
//! This is the default way to model tree nodes in these examples. Indices are
//! `Copy`, 4 bytes, survive `Vec` reallocation, map 1:1 onto on-disk page
//! numbers, and avoid fighting the borrow checker over parent/sibling links.

/// Typed index of a node inside an [`Arena`]. `u32` keeps nodes compact.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct NodeId(u32);

impl NodeId {
    pub fn index(self) -> usize {
        self.0 as usize
    }
}

#[derive(Debug)]
enum Slot<T> {
    Occupied(T),
    /// Free slot; holds the next free slot, forming an intrusive free list.
    Free {
        next_free: Option<NodeId>,
    },
}

/// Slab allocator: O(1) alloc/free, slots are reused LIFO.
#[derive(Debug)]
pub struct Arena<T> {
    slots: Vec<Slot<T>>,
    free_head: Option<NodeId>,
    len: usize,
}

impl<T> Default for Arena<T> {
    fn default() -> Self {
        Self::new()
    }
}

impl<T> Arena<T> {
    pub fn new() -> Self {
        Self {
            slots: Vec::new(),
            free_head: None,
            len: 0,
        }
    }

    pub fn with_capacity(capacity: usize) -> Self {
        Self {
            slots: Vec::with_capacity(capacity),
            free_head: None,
            len: 0,
        }
    }

    /// Number of live nodes.
    pub fn len(&self) -> usize {
        self.len
    }

    pub fn is_empty(&self) -> bool {
        self.len == 0
    }

    pub fn alloc(&mut self, value: T) -> NodeId {
        self.len += 1;
        match self.free_head {
            Some(id) => {
                let Slot::Free { next_free } = self.slots[id.index()] else {
                    unreachable!("free list points at an occupied slot");
                };
                self.free_head = next_free;
                self.slots[id.index()] = Slot::Occupied(value);
                id
            }
            None => {
                let id = NodeId(u32::try_from(self.slots.len()).expect("arena full"));
                self.slots.push(Slot::Occupied(value));
                id
            }
        }
    }

    /// Frees a slot and returns its value. Panics on double free.
    pub fn free(&mut self, id: NodeId) -> T {
        let slot = std::mem::replace(
            &mut self.slots[id.index()],
            Slot::Free {
                next_free: self.free_head,
            },
        );
        match slot {
            Slot::Occupied(value) => {
                self.free_head = Some(id);
                self.len -= 1;
                value
            }
            Slot::Free { next_free } => {
                // Undo the replace so the free list stays intact, then report the bug.
                self.slots[id.index()] = Slot::Free { next_free };
                panic!("double free of {id:?}");
            }
        }
    }

    pub fn get(&self, id: NodeId) -> Option<&T> {
        match self.slots.get(id.index())? {
            Slot::Occupied(value) => Some(value),
            Slot::Free { .. } => None,
        }
    }

    pub fn get_mut(&mut self, id: NodeId) -> Option<&mut T> {
        match self.slots.get_mut(id.index())? {
            Slot::Occupied(value) => Some(value),
            Slot::Free { .. } => None,
        }
    }

    /// Two distinct nodes mutably at once (e.g. node + sibling during a split).
    pub fn get_pair_mut(&mut self, a: NodeId, b: NodeId) -> Option<(&mut T, &mut T)> {
        let [x, y] = self.slots.get_disjoint_mut([a.index(), b.index()]).ok()?;
        match (x, y) {
            (Slot::Occupied(x), Slot::Occupied(y)) => Some((x, y)),
            _ => None,
        }
    }
}

/// `arena[id]` panics on a stale id, like slice indexing.
impl<T> std::ops::Index<NodeId> for Arena<T> {
    type Output = T;
    fn index(&self, id: NodeId) -> &T {
        self.get(id).expect("stale NodeId")
    }
}

impl<T> std::ops::IndexMut<NodeId> for Arena<T> {
    fn index_mut(&mut self, id: NodeId) -> &mut T {
        self.get_mut(id).expect("stale NodeId")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[derive(Debug, Default)]
    struct Node {
        keys: Vec<u64>,
        children: Vec<NodeId>,
        next_leaf: Option<NodeId>,
    }

    #[test]
    fn alloc_free_reuse() {
        let mut arena: Arena<Node> = Arena::new();
        let a = arena.alloc(Node::default());
        let b = arena.alloc(Node {
            keys: vec![1, 2],
            ..Node::default()
        });
        assert_eq!(arena.len(), 2);

        let freed = arena.free(a);
        assert!(freed.keys.is_empty());
        assert!(arena.get(a).is_none());

        let c = arena.alloc(Node::default());
        assert_eq!(c, a, "freed slot is reused");
        assert_eq!(arena[b].keys, [1, 2]);
    }

    #[test]
    fn link_nodes_by_index() {
        let mut arena: Arena<Node> = Arena::with_capacity(3);
        let left = arena.alloc(Node {
            keys: vec![1, 2],
            ..Node::default()
        });
        let right = arena.alloc(Node {
            keys: vec![5, 6],
            ..Node::default()
        });
        let root = arena.alloc(Node {
            keys: vec![5],
            children: vec![left, right],
            next_leaf: None,
        });
        arena[left].next_leaf = Some(right);

        // Move a key between siblings: needs both nodes mutably.
        let (l, r) = arena.get_pair_mut(left, right).unwrap();
        l.keys.push(r.keys.remove(0));
        arena[root].keys[0] = 6;

        assert_eq!(arena[left].keys, [1, 2, 5]);
        assert_eq!(arena[arena[root].children[1]].keys, [6]);
        assert!(arena.get_pair_mut(left, left).is_none());
    }

    #[test]
    #[should_panic(expected = "double free")]
    fn double_free_panics() {
        let mut arena: Arena<u8> = Arena::new();
        let id = arena.alloc(1);
        arena.free(id);
        arena.free(id);
    }
}
