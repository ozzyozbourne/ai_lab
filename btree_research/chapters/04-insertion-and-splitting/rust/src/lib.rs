//! Chapter 04: insertion and splitting.
//!
//! ```text
//! file              content                                   needs
//! base_node.rs      the node type (chapter 03)                -
//! base_search.rs    get, in_order, range (chapter 03)         node
//! base_validate.rs  the invariants as code                    node
//! base_stats.rs     shape, fill, text rendering               node
//! base_pool.rs      the slab: where nodes come from           node
//! base_insert.rs    put with bottom-up splitting              node, search, pool, btree
//! base_btree.rs     ties the parts together
//! topdown.rs        put with top-down splitting (textbook)    node, search, pool, btree
//! measure.rs        fill and split counts after N inserts     btree, topdown, prng
//! scenario.rs       what `cargo run` prints
//! ```
//!
//! The `base_*` files are copies from chapter 05 (the complete tree), with
//! `delete` trimmed away. `ops.rs` and `prng.rs` are copies from `common/`.

pub mod base_btree;
pub mod base_insert;
pub mod base_node;
pub mod base_pool;
pub mod base_search;
pub mod base_stats;
pub mod base_validate;
pub mod measure;
pub mod ops;
pub mod prng;
pub mod scenario;
pub mod topdown;

#[cfg(test)]
mod base_tests_insert;
#[cfg(test)]
mod tests_alloc;
#[cfg(test)]
mod tests_topdown;
