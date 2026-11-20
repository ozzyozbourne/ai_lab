// Copied from chapters/07-bplus-trees/rust/src/arena.rs; trimmed to the handle
// type and the error. The growable Arena<T> with its free list is NOT copied:
// this chapter preallocates a fixed node table and never frees a node (see
// blink.rs).

/// Handle of a node: an index into the node table. `NodeId::NIL` plays the
/// role of a null pointer (or of "page 0 = no page" in an on-disk format).
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

    /// Position in the node table. Never call on `NIL`.
    pub fn index(self) -> usize {
        assert!(!self.is_nil(), "NIL handle dereferenced");
        self.0 as usize
    }

    pub fn from_index(i: usize) -> NodeId {
        let raw = u32::try_from(i).expect("node table full");
        assert!(raw != u32::MAX, "node table full"); // u32::MAX is reserved for NIL
        NodeId(raw)
    }
}

/// The node table is used up. (Chapter 07: the node budget was exceeded.)
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct OutOfNodes;

impl std::fmt::Display for OutOfNodes {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("node table exhausted")
    }
}

impl std::error::Error for OutOfNodes {}
