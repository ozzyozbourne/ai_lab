//! Library root of chapter 27: a B+tree and an LSM-tree on the same counted
//! block device.
//!
//!   device.rs    the counted block device: reads, writes, blocks allocated
//!   base_*.rs    the B+tree of chapter 07, instrumented (changes: "ch27:")
//!   memtable.rs  skip list in two bump Vecs: the LSM-tree's mutable part
//!   run.rs       immutable sorted run: data blocks + index blocks, builder
//!   merge.rs     k-way merge with fixed buffers
//!   lsm.rs       Lsm: put, delete, get, range, flush, compaction, validate
//!   bench.rs     the same operation stream on both, counted per operation

pub mod base_arena;
pub mod base_delete;
pub mod base_insert;
pub mod base_node;
pub mod base_search;
pub mod base_tree;
pub mod base_validate;
pub mod base_walk;
pub mod bench;
pub mod device;
pub mod lsm;
pub mod memtable;
pub mod merge;
pub mod ops;
pub mod prng;
pub mod run;

#[cfg(test)]
mod tests;

pub use base_arena::{NodeId, OutOfNodes};
pub use base_node::Entry;
pub use base_tree::BPlusTree;
pub use base_walk::LeafWalker;
pub use device::{Counters, Device};
pub use lsm::Lsm;
pub use memtable::{Memtable, OutOfMemory};
