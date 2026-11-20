// Copied from chapters/07-bplus-trees/rust/src/node.rs and changed for
// chapter 24: a leaf entry is an index key (user key, tid) with a "dead" hint
// bit instead of a key with a value; a leaf has only a right link, and a page
// state (live / half-dead / deleted).
//! Page layout of the index, and the array surgery done inside one page.
//!
//!   * a LEAF holds index entries. An entry is NOT a row: it is the pair
//!     (user key, tid), where the tid names a row version in the version
//!     store (store.rs). Whether that version is visible to anyone is not
//!     recorded here, except for one bit: the `dead` hint.
//!   * an INTERNAL page holds separators and child handles, as in chapter 07.

use crate::base_arena::NodeId;

pub const MAX_ORDER: usize = 16;
/// A page of order M holds at most M-1 keys, but an insert lets it overflow
/// by exactly one key before it is split, so the arrays have room for M.
pub const KEY_CAPACITY: usize = MAX_ORDER;
pub const CHILD_CAPACITY: usize = MAX_ORDER + 1;

/// User keys are limited to 32 bits in this chapter so that an index key
/// fits in one u64 and base_search.rs can compare it as a plain integer.
pub const MAX_USER_KEY: u64 = u32::MAX as u64;

/// Index key = (user key, tid): the tid is the tie-breaker that makes every
/// entry unique even when one user key has many row versions (chapter 07,
/// "duplicates through a tie-breaker").
pub fn pack(user_key: u64, tid: NodeId) -> u64 {
    assert!(user_key <= MAX_USER_KEY);
    (user_key << 32) | tid.index() as u64
}

/// Smallest index key with this user key: where a search for the key starts.
pub fn pack_low(user_key: u64) -> u64 {
    assert!(user_key <= MAX_USER_KEY);
    user_key << 32
}

pub fn user_key(index_key: u64) -> u64 {
    index_key >> 32
}

pub fn tid_of(index_key: u64) -> NodeId {
    NodeId::from_index((index_key & 0xFFFF_FFFF) as usize)
}

/// Life cycle of a leaf page. Only an EMPTY page ever leaves `Live`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PageState {
    /// Reachable from its parent and from its left sibling.
    Live,
    /// Phase 1 done: no parent downlink any more, still in the sibling chain.
    HalfDead,
    /// Phase 2 done: out of the sibling chain too. The payload is the epoch
    /// at which it was unlinked. The page keeps its own right link, and must
    /// not be reused while any snapshot older than that epoch is open.
    Deleted(u64),
}

#[derive(Debug, Clone)]
pub struct Leaf {
    /// dead[i] belongs to keys[i]: "a scan saw that this entry's row version
    /// is dead to every snapshot". A HINT: false says nothing.
    pub dead: [bool; KEY_CAPACITY],
    /// Right sibling. There is no left link in this chapter.
    pub next: NodeId,
    pub state: PageState,
    /// Queue of deleted pages waiting to be recycled (oldest first).
    pub next_deleted: NodeId,
}

#[derive(Debug, Clone)]
pub struct Internal {
    /// children[i] holds keys <  keys[i]   (and >= keys[i-1]);
    /// children[len] holds keys >= keys[len-1].
    pub children: [NodeId; CHILD_CAPACITY],
}

#[derive(Debug, Clone)]
pub enum Kind {
    Leaf(Leaf),
    Internal(Internal),
}

#[derive(Debug, Clone)]
pub struct Node {
    /// Number of keys in use.
    pub len: usize,
    /// Sorted ascending, unique. Leaf: index keys. Internal: separators.
    pub keys: [u64; KEY_CAPACITY],
    pub kind: Kind,
}

impl Node {
    pub fn new_leaf() -> Node {
        Node {
            len: 0,
            keys: [0; KEY_CAPACITY],
            kind: Kind::Leaf(Leaf {
                dead: [false; KEY_CAPACITY],
                next: NodeId::NIL,
                state: PageState::Live,
                next_deleted: NodeId::NIL,
            }),
        }
    }

    pub fn new_internal() -> Node {
        Node {
            len: 0,
            keys: [0; KEY_CAPACITY],
            kind: Kind::Internal(Internal {
                children: [NodeId::NIL; CHILD_CAPACITY],
            }),
        }
    }

    pub fn is_leaf(&self) -> bool {
        matches!(self.kind, Kind::Leaf(_))
    }

    pub fn key_slice(&self) -> &[u64] {
        &self.keys[..self.len]
    }

    /// The len+1 child handles of an internal page.
    pub fn child_slice(&self) -> &[NodeId] {
        &self.internal().children[..self.len + 1]
    }

    // The four accessors below panic when the page is of the other kind,
    // which is what Zig's `node.kind.leaf` does in a safe build.

    pub fn leaf(&self) -> &Leaf {
        match &self.kind {
            Kind::Leaf(leaf) => leaf,
            Kind::Internal(_) => panic!("expected a leaf"),
        }
    }

    pub fn leaf_mut(&mut self) -> &mut Leaf {
        match &mut self.kind {
            Kind::Leaf(leaf) => leaf,
            Kind::Internal(_) => panic!("expected a leaf"),
        }
    }

    pub fn internal(&self) -> &Internal {
        match &self.kind {
            Kind::Internal(internal) => internal,
            Kind::Leaf(_) => panic!("expected an internal page"),
        }
    }

    pub fn internal_mut(&mut self) -> &mut Internal {
        match &mut self.kind {
            Kind::Internal(internal) => internal,
            Kind::Leaf(_) => panic!("expected an internal page"),
        }
    }

    /// Inserts an entry (hint clear) at position i, shifting the tail right.
    pub fn leaf_insert_at(&mut self, i: usize, index_key: u64) {
        let len = self.len;
        assert!(len < KEY_CAPACITY && i <= len);
        self.keys.copy_within(i..len, i + 1);
        self.keys[i] = index_key;
        let leaf = self.leaf_mut();
        leaf.dead.copy_within(i..len, i + 1);
        leaf.dead[i] = false;
        self.len += 1;
    }

    /// Removes the entry at position i, shifting the tail left.
    pub fn leaf_remove_at(&mut self, i: usize) {
        let len = self.len;
        assert!(i < len);
        self.keys.copy_within(i + 1..len, i);
        self.leaf_mut().dead.copy_within(i + 1..len, i);
        self.len -= 1;
    }

    /// Inserts separator `key` at key position i and `right` as the child to
    /// its right (child position i+1): what a parent does after child i split.
    pub fn internal_insert_at(&mut self, i: usize, key: u64, right: NodeId) {
        let len = self.len;
        assert!(len < KEY_CAPACITY && i <= len);
        self.keys.copy_within(i..len, i + 1);
        self.keys[i] = key;
        let children = &mut self.internal_mut().children;
        children.copy_within(i + 1..len + 1, i + 2);
        children[i + 1] = right;
        self.len += 1;
    }

    /// Removes separator i and the child to its right (child i+1).
    pub fn internal_remove_at(&mut self, i: usize) {
        let len = self.len;
        assert!(i < len);
        self.keys.copy_within(i + 1..len, i);
        self.internal_mut()
            .children
            .copy_within(i + 2..len + 1, i + 1);
        self.len -= 1;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pack_keeps_user_key_tid_order_and_round_trips() {
        let a = pack(7, NodeId::from_index(9));
        assert_eq!(user_key(a), 7);
        assert_eq!(tid_of(a).index(), 9);
        assert!(pack(7, NodeId::from_index(9)) < pack(8, NodeId::from_index(0)));
        assert!(pack_low(7) <= pack(7, NodeId::from_index(0)));
        // The largest user key still fits.
        assert_eq!(user_key(pack(MAX_USER_KEY, NodeId::from_index(9))), MAX_USER_KEY);
    }

    /// A key above 32 bits must stop the program, not be filed under its low
    /// bits. (Zig: the same check is an unconditional `@panic`, which a Zig
    /// test cannot catch; it is checked in every build mode there too.)
    #[test]
    #[should_panic(expected = "user_key <= MAX_USER_KEY")]
    fn a_user_key_above_32_bits_is_refused() {
        pack(MAX_USER_KEY + 1, NodeId::from_index(0));
    }

    #[test]
    fn leaf_insert_and_remove_keep_keys_and_hint_bits_aligned() {
        let mut n = Node::new_leaf();
        n.leaf_insert_at(0, 20);
        n.leaf_insert_at(0, 10);
        n.leaf_mut().dead[1] = true; // hint on 20
        n.leaf_insert_at(1, 15);
        assert_eq!(n.key_slice(), [10, 15, 20]);
        assert_eq!(n.leaf().dead[..3], [false, false, true]);
        n.leaf_remove_at(0);
        assert_eq!(n.key_slice(), [15, 20]);
        assert_eq!(n.leaf().dead[..2], [false, true]);
    }
}
