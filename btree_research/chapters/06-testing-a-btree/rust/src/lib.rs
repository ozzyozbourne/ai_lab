//! Chapter 06: testing a B-tree.
//!
//! ```text
//! base_*.rs       the B-tree of chapter 05 (the system under test), with
//!                 coverage points and three one-line fault seams
//! coverage.rs     counters that prove the tests reached the hard branches
//! alloc_count.rs  counting #[global_allocator] (the only `unsafe` in Part I)
//! fuzz.rs         swarm cases, operation generation, replay against the oracle
//! minimize.rs     shrink a failing sequence to a short reproducer
//! scenario.rs     what `cargo run` prints
//! tests.rs        the tests built from the pieces above
//! ```

pub mod alloc_count;
pub mod base_btree;
pub mod base_delete;
pub mod base_insert;
pub mod base_node;
pub mod base_pool;
pub mod base_search;
pub mod base_stats;
pub mod base_validate;
pub mod coverage;
pub mod fuzz;
pub mod minimize;
pub mod ops;
pub mod prng;
pub mod scenario;

/// Every allocation of this crate (library, tests and the `cargo run`
/// binary) goes through the counting wrapper.
#[global_allocator]
static GLOBAL: alloc_count::CountingAlloc = alloc_count::CountingAlloc;

#[cfg(test)]
mod tests;
