//! Chapter 13: overflow chains and free space.
//!
//!   base_storage.rs       Storage trait, FileStorage, MemStorage, Error   (chapter 09)
//!   base_pager.rs         Pager: a storage as an array of 4096-byte pages (chapter 09)
//!   base_buffer_pool.rs   BufferPool: pinned frames, dirty flags, CLOCK   (chapter 09)
//!   base_slotted_page.rs  SlottedPage: variable-length cells in one page  (chapter 10)
//!   disk_btree.rs         DiskBTree (chapter 12) + overflow chains, delete, free list
//!   workload.rs           seeded keys and values of every size class, the oracle
//!   tests.rs              model tests, fault injection, damaged files
//!   demo.rs               the fixed scenario printed by `cargo run`
pub mod base_buffer_pool;
pub mod base_pager;
pub mod base_slotted_page;
pub mod base_storage;
pub mod demo;
pub mod disk_btree;
pub mod prng;
pub mod workload;

#[cfg(test)]
mod tests;

pub use disk_btree::DiskBTree;

/// Test helper: a fresh, empty directory under the system temp directory,
/// removed again on drop. (Rust's std has no `tmpDir` like Zig's test kit.)
#[cfg(test)]
pub(crate) struct TempDir(pub std::path::PathBuf);

#[cfg(test)]
impl TempDir {
    pub(crate) fn new(name: &str) -> Self {
        let path = std::env::temp_dir().join(format!("ch13_{}_{}", std::process::id(), name));
        let _ = std::fs::remove_dir_all(&path);
        std::fs::create_dir_all(&path).expect("create temp dir");
        Self(path)
    }
}

#[cfg(test)]
impl Drop for TempDir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}
