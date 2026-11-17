//! Chapter 09: pages and the buffer pool.
//!
//!   storage.rs      Storage trait, FileStorage, MemStorage, the Error enum
//!   pager.rs        Pager: a storage seen as an array of 4096-byte pages
//!   buffer_pool.rs  BufferPool: pinned frames, dirty flags, CLOCK eviction
//!   workload.rs     seeded random workload + oracle (model test, demo part 3)
//!   demo.rs         the fixed scenario printed by `cargo run`
pub mod buffer_pool;
pub mod demo;
pub mod pager;
pub mod prng;
pub mod storage;
pub mod workload;

/// Test helper: a fresh, empty directory under the system temp directory,
/// removed again on drop. (Rust's std has no `tmpDir` like Zig's test kit.)
#[cfg(test)]
pub(crate) struct TempDir(pub std::path::PathBuf);

#[cfg(test)]
impl TempDir {
    pub(crate) fn new(name: &str) -> Self {
        let path = std::env::temp_dir().join(format!("ch09_{}_{}", std::process::id(), name));
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

#[cfg(test)]
mod tests {
    #[test]
    fn run_output_matches_expected_output_txt() {
        let tmp = super::TempDir::new("expected_output");
        let mut out = Vec::new();
        super::demo::run(&mut out, &tmp.0).expect("demo runs");
        assert_eq!(
            String::from_utf8(out).expect("utf-8"),
            include_str!("../../expected_output.txt")
        );
    }
}
