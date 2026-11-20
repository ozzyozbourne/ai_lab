//! Chapter 22: write-ahead log and crash recovery.
//!
//!   wal.rs        Wal: log format, commit, checkpoint, recovery      (this chapter)
//!   db.rs         Db: the disk tree behind the log                   (this chapter)
//!   machine.rs    Machine: two SimDisks with one power switch        (this chapter)
//!   adapter.rs    PageFile: chapter 12's storage on chapter 21's     (this chapter)
//!   crash.rs      the crash loop, with and without the log           (this chapter)
//!   demo.rs       the fixed scenario printed by `cargo run`
//!   tests.rs      tests of the log, of recovery and of the crash loop
//!
//!   base_storage / base_pager / base_buffer_pool / base_slotted_page /
//!   base_disk_btree / base_workload      copied from chapter 12
//!   base_page_storage / base_sim_disk / base_checksum   copied from chapter 21
//!   prng / crc32                         copied from common/
pub mod adapter;
pub mod base_buffer_pool;
pub mod base_checksum;
pub mod base_disk_btree;
pub mod base_page_storage;
pub mod base_pager;
pub mod base_sim_disk;
pub mod base_slotted_page;
pub mod base_storage;
pub mod base_workload;
pub mod crash;
pub mod crc32;
pub mod db;
pub mod demo;
pub mod machine;
pub mod prng;
pub mod wal;

//TESTS

pub use db::Db;
pub use wal::Wal;

/// Test helper of the copied chapter 12 files: a fresh, empty directory under
/// the system temp directory, removed again on drop.
#[cfg(test)]
pub(crate) struct TempDir(pub std::path::PathBuf);

#[cfg(test)]
impl TempDir {
    pub(crate) fn new(name: &str) -> Self {
        let path = std::env::temp_dir().join(format!("ch22_{}_{}", std::process::id(), name));
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
