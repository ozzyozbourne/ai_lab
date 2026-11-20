//! Chapter 14: split policies and fill factor.
//!
//! The interesting code is in `split` (the decision: where to cut a full
//! page) and `pages` (the page model the decision is tried on); `report`
//! runs the experiment that `cargo run` prints.

pub mod pages;
pub mod prng;
pub mod report;
pub mod split;
