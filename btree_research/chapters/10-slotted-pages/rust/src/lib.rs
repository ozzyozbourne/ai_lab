//! Chapter 10: slotted pages. Library root; `src/main.rs` prints the demo.

pub mod demo;
pub mod ops;
pub mod slotted_page;
pub mod workload;

#[cfg(test)]
mod model_test;

pub use slotted_page::SlottedPage;
