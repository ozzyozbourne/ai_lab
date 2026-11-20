//! Library root of chapter 07: an in-memory B+tree on an index arena.
//!
//! One concern per file, so that later chapters can copy exactly what they
//! need (as `base_*.rs`):
//!
//!   arena.rs     NodeId handles, Arena<T>: Vec of slots + free list + budget
//!   node.rs      Node layout (leaf / internal) and in-node array surgery
//!   tree.rs      BPlusTree: fields, invariants, constructors
//!   search.rs    lower_bound / upper_bound / child_index, find_leaf, get
//!   insert.rs    put: leaf split (copy-up), internal split (push-up)
//!   delete.rs    delete: borrow, merge, root shrink
//!   walk.rs      LeafWalker: minimal forward walk over the leaf chain
//!   validate.rs  every invariant as code
//!   dump.rs      text rendering
//!
//! `get`, `put`, `delete` and `validate` are methods of `BPlusTree`; each is
//! defined in an `impl BPlusTree` block in its own file.

pub mod arena;
pub mod delete;
pub mod dump;
pub mod insert;
pub mod node;
pub mod ops;
pub mod search;
pub mod tree;
pub mod validate;
pub mod walk;

#[cfg(test)]
mod tests;

pub use arena::{Arena, NodeId, OutOfNodes};
pub use node::{Entry, Node};
pub use tree::{BPlusTree, Stats};
pub use validate::Violation;
pub use walk::LeafWalker;
