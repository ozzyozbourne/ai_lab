//! Chapter 02: searching a sorted node (library part).
//!
//! The demo program in main.rs uses only some of these functions; the tests
//! use all of them. Putting the modules in a library keeps every `pub fn`
//! reachable, so the compiler does not report the rest as dead code.

pub mod node;
pub mod ops;
pub mod prng;
pub mod search;
pub mod trace;
