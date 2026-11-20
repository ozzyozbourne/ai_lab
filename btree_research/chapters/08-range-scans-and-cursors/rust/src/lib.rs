//! Library root of chapter 08: range scans and cursors on the chapter 07
//! B+tree.
//!
//!   base_*.rs        the B+tree, copied unchanged from chapter 07
//!   tree.rs          Tree = B+tree + a change counter (`version`)
//!   bounds.rs        Bound (unbounded / included / excluded), prefix_range
//!   cursor.rs        Seek, Position, Cursor<P>: save key and re-seek
//!   link_cursor.rs   LinkPosition: leaf + index, follows sibling links
//!   stack_cursor.rs  StackPosition: root-to-leaf path, no sibling links
//!   scan.rs          Scan<P>: range scan in either direction
//!   model.rs         seeded model run against the oracle

pub mod base_arena;
pub mod base_delete;
pub mod base_dump;
pub mod base_insert;
pub mod base_node;
pub mod base_search;
pub mod base_tree;
pub mod base_validate;
pub mod base_walk;
pub mod bounds;
pub mod cursor;
pub mod link_cursor;
pub mod model;
pub mod ops;
pub mod prng;
pub mod scan;
pub mod stack_cursor;
pub mod tree;

#[cfg(test)]
mod tests;

pub use base_arena::{NodeId, OutOfNodes};
pub use base_node::Entry;
pub use base_tree::BPlusTree;
pub use base_walk::LeafWalker;
pub use bounds::{Bound, Direction};
pub use cursor::{Cursor, Position, Seek, State, Stats};
pub use link_cursor::{LinkCursor, LinkPosition};
pub use scan::{Scan, ScanIter};
pub use stack_cursor::{Frame, StackCursor, StackPosition};
pub use tree::Tree;
