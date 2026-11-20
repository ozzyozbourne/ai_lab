//! Template crate for the B-tree teaching examples.
//!
//! Conventions (see `ZIG_CHEATSHEET.md`, section "Rust conventions"):
//! * edition 2024, std only, `unsafe` forbidden unless a chapter is about layout;
//! * nodes live in an arena (`Vec<Node>`) and refer to each other by index
//!   (`NodeId`), not by pointer or `Rc<RefCell<_>>`;
//! * page-oriented code uses `[u8; PAGE_SIZE]` buffers and
//!   `u32::from_le_bytes` / `to_le_bytes`, plus `FileExt::read_at` / `write_at`.

pub mod arena;
pub mod boxed;
pub mod pager;
pub mod rng;

pub use arena::{Arena, NodeId};
pub use pager::{PAGE_SIZE, Page, Pager};

/// Index of the first element in sorted `keys` that is `>= key`
/// (same contract as Zig's `std.sort.lowerBound`).
pub fn lower_bound<K: Ord>(keys: &[K], key: &K) -> usize {
    keys.partition_point(|k| k < key)
}

/// Index of the first element in sorted `keys` that is `> key`
/// (same contract as Zig's `std.sort.upperBound`).
pub fn upper_bound<K: Ord>(keys: &[K], key: &K) -> usize {
    keys.partition_point(|k| k <= key)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bounds() {
        let keys = [10, 20, 20, 30];
        assert_eq!(lower_bound(&keys, &20), 1);
        assert_eq!(upper_bound(&keys, &20), 3);
        assert_eq!(lower_bound(&keys, &99), 4);
        assert_eq!(keys.binary_search(&30), Ok(3));
        assert_eq!(keys.binary_search(&25), Err(3)); // Err(insertion point)
    }
}
