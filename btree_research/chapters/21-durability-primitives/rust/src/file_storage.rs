//! `FileStorage`: the `Storage` trait over a real file.
//!
//! `write_page` is pwrite(2): the bytes land in the operating system's page
//! cache and the call returns. `sync` is fsync(2): the kernel pushes the cached
//! pages to the device and asks the device to flush its own volatile cache. We
//! cannot cut the power in a unit test, which is why `SimDisk` exists; this
//! file is here so the same code can be pointed at a real disk.

use std::fs::{File, OpenOptions};
use std::io;
use std::os::unix::fs::FileExt;
use std::path::Path;

use crate::storage::{PAGE_SIZE, Page, Storage, StorageError};

#[derive(Debug)]
pub struct FileStorage {
    file: File,
    /// Cached so that `size()` cannot fail; the file is ours alone.
    page_count: u64,
}

impl FileStorage {
    /// Largest page number + 1 this implementation accepts: byte offsets in
    /// a file are signed 64-bit numbers.
    pub const MAX_PAGES: u64 = (1 << 63) / PAGE_SIZE as u64;

    /// Create or open `path` for reading and writing, keeping existing
    /// contents. The file must be a whole number of pages.
    pub fn open(path: impl AsRef<Path>) -> io::Result<Self> {
        let file = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .open(path)?;
        let len = file.metadata()?.len();
        if len % PAGE_SIZE as u64 != 0 {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "file is not a whole number of pages",
            ));
        }
        Ok(Self {
            file,
            page_count: len / PAGE_SIZE as u64,
        })
    }
}

impl Storage for FileStorage {
    fn read_page(&mut self, page_no: u64, out: &mut Page) -> Result<(), StorageError> {
        if page_no >= self.page_count {
            return Err(StorageError::OutOfBounds);
        }
        self.file
            .read_exact_at(out, page_no * PAGE_SIZE as u64)
            .map_err(|_| StorageError::InputOutput)
    }

    fn write_page(&mut self, page_no: u64, page: &Page) -> Result<(), StorageError> {
        if page_no >= Self::MAX_PAGES {
            return Err(StorageError::OutOfBounds);
        }
        // A write past the end leaves a hole that the file system reads back
        // as zeroes: the same behaviour SimDisk implements by hand.
        self.file
            .write_all_at(page, page_no * PAGE_SIZE as u64)
            .map_err(|_| StorageError::InputOutput)?;
        self.page_count = self.page_count.max(page_no + 1);
        Ok(())
    }

    fn sync(&mut self) -> Result<(), StorageError> {
        // If fsync fails, the kernel may already have dropped the dirty pages:
        // retrying and getting "success" proves nothing. The only safe reaction
        // is to stop and recover from the log (chapter 22), so we report it.
        self.file.sync_all().map_err(|_| StorageError::InputOutput)
    }

    fn size(&self) -> u64 {
        self.page_count
    }
}

/// A directory under the system temp dir that is removed on drop (std has no
/// equivalent of Zig's `std.testing.tmpDir`).
#[cfg(test)]
pub(crate) struct TmpDir(pub std::path::PathBuf);

#[cfg(test)]
impl TmpDir {
    pub(crate) fn new(name: &str) -> Self {
        let dir = std::env::temp_dir().join(format!("ch21_{}_{name}", std::process::id()));
        std::fs::create_dir_all(&dir).expect("create temp dir");
        Self(dir)
    }
}

#[cfg(test)]
impl Drop for TmpDir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn file_storage_write_sync_reopen_read_back() {
        let tmp = TmpDir::new("reopen");
        let path = tmp.0.join("data.db");
        let mut page: Page = [0; PAGE_SIZE];
        {
            let mut s = FileStorage::open(&path).unwrap();
            assert_eq!(s.size(), 0);
            assert_eq!(s.read_page(0, &mut page), Err(StorageError::OutOfBounds));

            page.fill(b'A');
            s.write_page(2, &page).unwrap(); // pages 0 and 1 become a zero-filled hole
            s.sync().unwrap();
            assert_eq!(s.size(), 3);
        }

        let mut s = FileStorage::open(&path).unwrap();
        assert_eq!(s.size(), 3);
        s.read_page(2, &mut page).unwrap();
        assert!(page.iter().all(|&b| b == b'A'));
        s.read_page(1, &mut page).unwrap();
        assert!(page.iter().all(|&b| b == 0));
    }

    #[test]
    fn file_storage_a_hole_below_an_unsynced_write_reads_as_zeroes() {
        let tmp = TmpDir::new("hole");
        let mut s = FileStorage::open(tmp.0.join("hole.db")).unwrap();
        let mut page: Page = [b'A'; PAGE_SIZE];
        s.write_page(2, &page).unwrap(); // no sync
        assert_eq!(s.size(), 3);
        s.read_page(1, &mut page).unwrap();
        assert!(page.iter().all(|&b| b == 0));
        assert_eq!(s.read_page(3, &mut page), Err(StorageError::OutOfBounds));
    }

    #[test]
    fn file_storage_refuses_a_page_number_that_does_not_fit_a_file_offset() {
        let tmp = TmpDir::new("big");
        let mut s = FileStorage::open(tmp.0.join("big.db")).unwrap();
        let page: Page = [b'A'; PAGE_SIZE];
        assert_eq!(
            s.write_page(FileStorage::MAX_PAGES, &page),
            Err(StorageError::OutOfBounds)
        );
        assert_eq!(
            s.write_page(u64::MAX, &page),
            Err(StorageError::OutOfBounds)
        );
        assert_eq!(s.size(), 0);
    }

    #[test]
    fn file_storage_rejects_a_file_that_is_not_whole_pages() {
        let tmp = TmpDir::new("bad");
        let path = tmp.0.join("bad.db");
        std::fs::write(&path, "short").unwrap();
        let err = FileStorage::open(&path).unwrap_err();
        assert_eq!(err.kind(), io::ErrorKind::InvalidData);
    }
}
