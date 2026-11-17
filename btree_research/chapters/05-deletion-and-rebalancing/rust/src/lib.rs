//! Chapter 05: deletion and rebalancing. The complete in-memory B-tree.
//!
//!   node.rs      the node type                      (chapter 03)
//!   pool.rs      where nodes come from and go back to
//!   search.rs    get, in_order, range               (chapter 03)
//!   insert.rs    put, split                         (chapter 04)
//!   delete.rs    delete, borrow, merge, root shrink (chapter 05, this one)
//!   validate.rs  the invariants as code             (chapter 06 builds on it)
//!   stats.rs     shape, fill, text rendering
//!   btree.rs     ties the sections together
//!   scenario.rs  what `cargo run` prints

pub mod btree;
pub mod delete;
pub mod insert;
pub mod node;
pub mod ops;
pub mod pool;
pub mod prng;
pub mod scenario;
pub mod search;
pub mod stats;
pub mod validate;

#[cfg(test)]
mod tests;
