//! Chapter 05: deletion and rebalancing. The complete in-memory B-tree.
//!
//! ```text
//! file         content                              needs
//! node.rs      the node type (chapter 03)           -
//! search.rs    get, in_order, range (chapter 03)    node
//! validate.rs  the invariants as code               node
//! stats.rs     shape, fill, text rendering          node
//! pool.rs      the slab: where nodes come from      node
//! insert.rs    put, split (chapter 04)              node, search, pool, btree
//! delete.rs    delete, borrow, merge, root shrink   node, search, pool, btree
//! btree.rs     ties the sections together
//! scenario.rs  what `cargo run` prints
//! ```
//!
//! Copying a part of the tree into another chapter:
//!
//! ```text
//! search only      node, search, validate, stats (nodes in a Vec<Node>,
//!                  or btree.rs without put, delete and Counters)
//! search + insert  the above + pool, insert, btree.rs without delete and
//!                  the delete counters; tests_insert.rs
//! everything       all of the above + delete.rs, tests_delete.rs
//! ```

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
mod tests_delete;
#[cfg(test)]
mod tests_insert;
