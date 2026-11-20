//! Chapter 30: tracing a real insert.
//!
//! Copied from chapters/12-disk-backed-bplus-tree (see each file's header):
//!   base_storage.rs, base_pager.rs, base_buffer_pool.rs,
//!   base_slotted_page.rs, disk_btree.rs, prng.rs, workload.rs
//! New in this chapter:
//!   resumable.rs   InsertOp and GetOp: operations that yield instead of waiting
//!   scheduler.rs   SimDisk (reads complete later) and the cooperative Scheduler
//!   tests.rs       byte-identity, every suspension point, re-entry, failures
//!   demo.rs        the fixed scenario printed by `cargo run`
pub mod base_buffer_pool;
pub mod base_pager;
pub mod base_slotted_page;
pub mod base_storage;
pub mod demo;
pub mod disk_btree;
pub mod prng;
pub mod resumable;
pub mod scheduler;
pub mod workload;

#[cfg(test)]
mod tests;

pub use disk_btree::DiskBTree;

/// Test helper of the copied base files: a fresh, empty directory under the
/// system temp directory, removed again on drop.
#[cfg(test)]
pub(crate) struct TempDir(pub std::path::PathBuf);

#[cfg(test)]
impl TempDir {
    pub(crate) fn new(name: &str) -> Self {
        let path = std::env::temp_dir().join(format!("ch30_{}_{}", std::process::id(), name));
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
