//! Library root of chapter 19: one B+tree on a preallocated node table,
//! shared by several threads under three lock protocols.
//!
//!   base_node.rs    Node layout (copied from chapter 07, trimmed)
//!   base_search.rs  binary search inside a node (copied from chapter 07)
//!   table.rs        NodeTable: Box<[RwLock<Node>]>, atomic bump
//!   tree.rs         Tree: fields, the three protocols, the test hook
//!   plain.rs        get / put under a tree-wide lock
//!   coupled.rs      get / put with latch coupling and the safe-node rule
//!   insert.rs       leaf insert and splits, shared by plain and coupled
//!   validate.rs     every invariant as code (quiescent)
//!   dump.rs         text rendering and leaf-chain walk (quiescent)
//!   probe.rs        freeze one operation, run another: deterministic
//!   stress.rs       bounded multi-threaded workload and its check

pub mod base_node;
pub mod base_search;
pub mod coupled;
pub mod dump;
pub mod insert;
pub mod ops;
pub mod plain;
pub mod prng;
pub mod probe;
pub mod stress;
pub mod table;
pub mod tree;
pub mod validate;

#[cfg(test)]
mod tests;

pub use base_node::{Entry, Node, NodeId, OutOfNodes};
pub use table::NodeTable;
pub use tree::{Event, Hook, Mode, Point, Protocol, Stats, Tree};
pub use validate::Violation;

/// Canonical hand example of chapters 03 to 08.
pub const CANONICAL: [u64; 12] = [10, 20, 5, 6, 12, 30, 7, 17, 3, 25, 1, 15];

pub const PROTOCOLS: [Protocol; 3] = [
    Protocol::GlobalMutex,
    Protocol::GlobalRwLock,
    Protocol::LatchCoupling,
];

pub fn protocol_name(p: Protocol) -> &'static str {
    match p {
        Protocol::GlobalMutex => "global mutex",
        Protocol::GlobalRwLock => "global rwlock",
        Protocol::LatchCoupling => "latch coupling",
    }
}
