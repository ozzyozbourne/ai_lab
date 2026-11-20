//! Library root of chapter 20: a Lehman-Yao B-link tree.
//!
//!   base_handle.rs  NodeId, OutOfNodes                       (from chapter 07)
//!   base_node.rs    keys + values / children of one node     (from chapter 07)
//!   base_search.rs  lower_bound / upper_bound / child_index  (from chapter 07)
//!   blink.rs        BLinkTree: node table, latches, high key, right link
//!   search.rs       Descent: one latch at a time, move right
//!   insert.rs       put: split step 1, split step 2, finishing a split
//!   validate.rs     every invariant as code
//!   dump.rs         text rendering
//!   stress.rs       bounded multi-threaded workload with per-thread logs
//!   prng.rs, ops.rs copied from common/

pub mod base_handle;
pub mod base_node;
pub mod base_search;
pub mod blink;
pub mod dump;
mod insert;
pub mod ops;
pub mod prng;
pub mod search;
pub mod stress;
pub mod validate;

#[cfg(test)]
mod tests;

pub use base_handle::{NodeId, OutOfNodes};
pub use blink::{BLinkTree, Page, Stats};
pub use search::{Descent, Lookup, Mode, Step};
pub use validate::Violation;
