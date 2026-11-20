//! Library root of chapter 23: a copy-on-write B+tree.
//!
//!   base_node.rs    Node layout and in-node surgery   (from chapter 07, no leaf links)
//!   base_search.rs  lower_bound / upper_bound / child_index   (from chapter 07)
//!   crc32.rs, ops.rs                                          (from common/)
//!   meta.rs         two-slot checksummed metapage: encode, decode, pick
//!   store.rs        PageStore: page slab, free list, meta slots
//!   read.rs         View: get, stack cursor, range
//!   db.rs           Db: committed root, snapshots (refcounted), pending frees
//!   txn.rs          WriteTxn: path copying, put, delete, commit, abort
//!   validate.rs     every invariant as code
//!   dump.rs         text rendering

pub mod base_node;
pub mod base_search;
pub mod crc32;
pub mod db;
pub mod dump;
pub mod meta;
pub mod ops;
pub mod read;
pub mod store;
pub mod txn;
pub mod validate;

#[cfg(test)]
mod tests;

pub use base_node::{Entry, Node, PageId};
pub use db::{Db, NoValidMeta, Snapshot, Stats};
pub use meta::Meta;
pub use read::{Cursor, View};
pub use store::PageStore;
pub use txn::{CommitInfo, TxnError, WriteTxn};
pub use validate::Violation;
