//! Chapter 16: bulk loading.
//!
//!   bptree.rs  the compact in-memory B+tree with a page-write counter
//!   bulk.rs    the bottom-up loader (start reading here)
//!   report.rs  the scenario printed by `cargo run`

pub mod bptree;
pub mod bulk;
#[cfg(test)]
#[allow(dead_code)]
mod ops;
#[allow(dead_code)]
mod prng;
pub mod report;
