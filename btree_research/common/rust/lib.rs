//! Crate root for common/rust: only wires the files together so that
//! `cargo test` runs every test. Chapters do NOT copy this file.
pub mod crc32;
pub mod hexdump;
pub mod ops;
pub mod prng;

#[cfg(test)]
mod golden_test;
