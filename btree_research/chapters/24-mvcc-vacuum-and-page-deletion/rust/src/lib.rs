//! Library root of chapter 24: MVCC garbage in a B+tree index, VACUUM, and
//! the deletion and recycling of empty pages. Single-threaded model.
//!
//!   base_arena.rs   (ch. 07) NodeId handles, Arena<T>: Vec of slots + free list + budget
//!   base_node.rs    (ch. 07, changed) page layout, (key, tid) entries, hint bits, page states
//!   base_search.rs  (ch. 07, trimmed) binary searches inside a page
//!   store.rs        row versions (xmin, xmax), transaction counter, snapshots, visibility
//!   index.rs        the B+tree: insert, garbage-before-split, two-phase page deletion, recycle
//!   db.rs           Db (put / delete / get / vacuum) and the snapshot Cursor
//!   validate.rs     every invariant as code
//!   dump.rs         text rendering

pub mod base_arena;
pub mod base_node;
pub mod base_search;
pub mod db;
pub mod dump;
pub mod index;
pub mod ops;
pub mod store;
pub mod validate;

#[cfg(test)]
mod tests;

pub use base_arena::{Arena, NodeId, OutOfNodes};
pub use db::{Cursor, DanglingLink, Db, ReadStats, Row, VacuumOptions, VacuumReport};
pub use index::{Index, Stats};
pub use store::{Store, Version};
pub use validate::Violation;
