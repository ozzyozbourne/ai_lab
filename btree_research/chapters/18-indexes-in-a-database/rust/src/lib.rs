//! Library root of chapter 18: a tiny table engine on top of the chapter 07
//! B+tree, in two layouts (clustered, heap + index).
//!
//!   base_*.rs   the in-memory B+tree, copied from chapter 07
//!   row.rs      the table's row, and composite index keys packed into u64
//!   cursor.rs   cost counters and the counting range cursor
//!   heap.rs     the heap: rows addressed by TID
//!   table.rs    Table: insert, delete, unique check, the four kinds of query
//!   prng.rs     SplitMix64 (copied from common/)

pub mod base_arena;
pub mod base_delete;
pub mod base_dump;
pub mod base_insert;
pub mod base_node;
pub mod base_ops;
pub mod base_search;
pub mod base_tree;
pub mod base_validate;
pub mod base_walk;
pub mod cursor;
pub mod heap;
pub mod prng;
pub mod row;
pub mod table;

#[cfg(test)]
mod base_tests;
#[cfg(test)]
mod tests;

pub use base_dump as dump;
pub use base_tree::BPlusTree;
pub use base_walk::LeafWalker;
pub use cursor::{Counters, Cursor};
pub use heap::Heap;
pub use row::{KeyRange, Locator, Row};
pub use table::{InsertError, Layout, Table};
