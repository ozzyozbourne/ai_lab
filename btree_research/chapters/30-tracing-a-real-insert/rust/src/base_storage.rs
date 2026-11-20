// Copied from chapters/12-disk-backed-bplus-tree/rust/src/base_storage.rs, which has it from:
// Copied from chapters/09-pages-and-the-buffer-pool/rust/src/storage.rs; behaviour unchanged (only the
// crate:: paths were renamed to the base_* modules of this chapter).
//! storage.rs: the "disk" underneath the pager, as a small trait.
//!
//! A `Storage` is a growable array of bytes with four operations: read at an
//! offset, write at an offset, report the size, and sync. It knows nothing
//! about pages. Keeping it this small is what lets later chapters swap the
//! real file for an in-memory disk (tests) or a simulated disk that tears and
//! drops writes (crash testing) without touching the pager or the buffer pool.
//!
//! The Zig version builds the interface by hand (pointer + function table);
//! here it is a trait, used as `Box<dyn Storage>`.
//!
//! Two implementations live here:
//!   * `FileStorage`: a real file, positional I/O (pread / pwrite / fsync).
//!   * `MemStorage`:  a byte array, with optional injected read and write failures.

use std::cell::RefCell;
use std::fmt;
use std::fs::{File, OpenOptions};
use std::io;
use std::os::unix::fs::FileExt;
use std::path::Path;
use std::rc::Rc;

/// Every error of this chapter, in one flat enum. Zig merges error sets with
/// `||` (`Pager.Error = Storage.Error || error{...}`); the closest Rust
/// equivalent that keeps the same names is a single enum.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Error {
    /// Storage: the read range extends past the end of the storage.
    ShortRead,
    /// Storage: the device (or the injected fault) refused the call.
    StorageFailure,
    /// Pager: the storage size is not a whole number of pages, or it holds
    /// more pages than a 32-bit page id can number.
    CorruptFile,
    /// Pager: `allocate_page` when every page id is in use. The file is not
    /// damaged, it is full.
    FileFull,
    /// Pager: the page id is >= page_count.
    PageOutOfRange,
    /// Buffer pool: every frame is pinned, nothing can be evicted.
    AllFramesPinned,
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "error.{self:?}")
    }
}

impl std::error::Error for Error {}

impl From<io::Error> for Error {
    /// Like the Zig backends, collapse OS errors onto the two storage errors.
    fn from(e: io::Error) -> Self {
        match e.kind() {
            io::ErrorKind::UnexpectedEof => Error::ShortRead,
            _ => Error::StorageFailure,
        }
    }
}

pub trait Storage {
    /// Fill `buffer` completely from `offset`, or fail with `ShortRead`.
    fn read(&mut self, offset: u64, buffer: &mut [u8]) -> Result<(), Error>;
    /// Write all of `bytes` at `offset`. Writing at or past the end grows the
    /// storage; a gap is filled with zero bytes.
    fn write(&mut self, offset: u64, bytes: &[u8]) -> Result<(), Error>;
    /// Current size in bytes.
    fn size(&mut self) -> Result<u64, Error>;
    /// Ask for everything written so far to be made durable (fsync). What that
    /// really guarantees is the subject of chapter 21.
    fn sync(&mut self) -> Result<(), Error>;
}

/// A real file. Closed when dropped.
#[derive(Debug)]
pub struct FileStorage {
    file: File,
}

impl FileStorage {
    /// Create a new, empty file (an existing file is truncated).
    pub fn create(path: impl AsRef<Path>) -> io::Result<Self> {
        let file = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(true)
            .open(path)?;
        Ok(Self { file })
    }

    /// Open an existing file for reading and writing; `NotFound` if absent.
    pub fn open(path: impl AsRef<Path>) -> io::Result<Self> {
        let file = OpenOptions::new().read(true).write(true).open(path)?;
        Ok(Self { file })
    }
}

impl Storage for FileStorage {
    fn read(&mut self, offset: u64, buffer: &mut [u8]) -> Result<(), Error> {
        // read_exact_at loops over pread; hitting EOF is `UnexpectedEof`.
        Ok(self.file.read_exact_at(buffer, offset)?)
    }

    fn write(&mut self, offset: u64, bytes: &[u8]) -> Result<(), Error> {
        // pwrite past the end extends the file; the OS zero-fills any gap.
        Ok(self.file.write_all_at(bytes, offset)?)
    }

    fn size(&mut self) -> Result<u64, Error> {
        Ok(self.file.metadata()?.len())
    }

    fn sync(&mut self) -> Result<(), Error> {
        Ok(self.file.sync_all()?)
    }
}

/// A disk made of memory. Used by tests and by the workload part of the demo,
/// and the starting point for the simulated disk of chapter 21.
///
/// `MemStorage` is a cheap handle: `clone()` gives a second handle to the SAME
/// bytes, like opening one file twice. A test gives one handle to the pager
/// (which owns its storage as `Box<dyn Storage>`) and keeps the other to look
/// at the bytes or to inject a fault. In Zig the test simply keeps a pointer.
#[derive(Debug, Clone, Default)]
pub struct MemStorage {
    disk: Rc<RefCell<MemDisk>>,
}

#[derive(Debug, Default)]
struct MemDisk {
    bytes: Vec<u8>,
    writes_before_failure: Option<u64>,
    reads_before_failure: Option<u64>,
    sync_count: u64,
}

impl MemStorage {
    pub fn new() -> Self {
        Self::default()
    }

    /// A copy of the current contents.
    pub fn bytes(&self) -> Vec<u8> {
        self.disk.borrow().bytes.clone()
    }

    /// Fault injection: with `Some(n)`, `n` more writes succeed and every
    /// write after that fails with `StorageFailure`. `None` = never fail.
    pub fn set_writes_before_failure(&self, n: Option<u64>) {
        self.disk.borrow_mut().writes_before_failure = n;
    }

    /// The same countdown for reads.
    pub fn set_reads_before_failure(&self, n: Option<u64>) {
        self.disk.borrow_mut().reads_before_failure = n;
    }

    pub fn sync_count(&self) -> u64 {
        self.disk.borrow().sync_count
    }
}

impl Storage for MemStorage {
    fn read(&mut self, offset: u64, buffer: &mut [u8]) -> Result<(), Error> {
        let mut disk = self.disk.borrow_mut();
        if let Some(left) = disk.reads_before_failure.as_mut() {
            if *left == 0 {
                return Err(Error::StorageFailure);
            }
            *left -= 1;
        }
        // An offset so large that the end cannot be computed is past the end
        // of any storage.
        let range = usize::try_from(offset)
            .ok()
            .and_then(|start| Some(start..start.checked_add(buffer.len())?));
        match range.and_then(|range| disk.bytes.get(range)) {
            Some(bytes) => {
                buffer.copy_from_slice(bytes);
                Ok(())
            }
            None => Err(Error::ShortRead),
        }
    }

    fn write(&mut self, offset: u64, bytes: &[u8]) -> Result<(), Error> {
        let mut disk = self.disk.borrow_mut();
        if let Some(left) = disk.writes_before_failure.as_mut() {
            if *left == 0 {
                return Err(Error::StorageFailure);
            }
            *left -= 1;
        }
        // A range that cannot be addressed is a range the "disk" cannot hold.
        let start = usize::try_from(offset).map_err(|_| Error::StorageFailure)?;
        let end = start
            .checked_add(bytes.len())
            .ok_or(Error::StorageFailure)?;
        let len = disk.bytes.len();
        if end > len {
            // Grow like a file does: new bytes read back as zero. `resize`
            // alone would abort the process when memory runs out; reserving
            // first turns that into an error, the "disk full" of this disk.
            disk.bytes
                .try_reserve(end - len)
                .map_err(|_| Error::StorageFailure)?;
            disk.bytes.resize(end, 0);
        }
        disk.bytes[start..end].copy_from_slice(bytes);
        Ok(())
    }

    fn size(&mut self) -> Result<u64, Error> {
        Ok(self.disk.borrow().bytes.len() as u64)
    }

    fn sync(&mut self) -> Result<(), Error> {
        self.disk.borrow_mut().sync_count += 1; // nothing to flush; just count
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::TempDir;

    #[test]
    fn mem_storage_write_read_back_grow_with_a_zero_filled_gap_short_read() {
        let mem = MemStorage::new();
        let mut s = mem.clone();

        assert_eq!(s.size(), Ok(0));
        s.write(0, b"abcd").unwrap();
        s.write(8, b"xy").unwrap(); // leaves a gap at 4..8
        assert_eq!(s.size(), Ok(10));

        let mut buf = [0u8; 10];
        s.read(0, &mut buf).unwrap();
        assert_eq!(&buf, b"abcd\0\0\0\0xy");
        assert_eq!(s.read(4, &mut buf), Err(Error::ShortRead));
        s.sync().unwrap();
        assert_eq!(mem.sync_count(), 1);
    }

    #[test]
    fn mem_storage_injected_write_failure() {
        let mem = MemStorage::new();
        let mut s = mem.clone();

        mem.set_writes_before_failure(Some(1));
        s.write(0, b"ok").unwrap();
        assert_eq!(s.write(0, b"no"), Err(Error::StorageFailure));
        assert_eq!(mem.bytes(), b"ok"); // the failed write changed nothing
        mem.set_writes_before_failure(None);
        s.write(0, b"go").unwrap();
    }

    #[test]
    fn mem_storage_injected_read_failure() {
        let mem = MemStorage::new();
        let mut s = mem.clone();
        s.write(0, b"data").unwrap();

        let mut buf = [b'.'; 4];
        mem.set_reads_before_failure(Some(1));
        s.read(0, &mut buf).unwrap();
        assert_eq!(&buf, b"data");
        buf.fill(b'.');
        assert_eq!(s.read(0, &mut buf), Err(Error::StorageFailure));
        assert_eq!(&buf, b"...."); // the failed read filled nothing
        mem.set_reads_before_failure(None);
        s.read(0, &mut buf).unwrap();
        assert_eq!(&buf, b"data");
    }

    #[test]
    fn mem_storage_offsets_near_the_end_of_the_address_space_are_errors_not_overflows() {
        let mem = MemStorage::new();
        let mut s = mem.clone();
        s.write(0, b"data").unwrap();
        let mut buf = [0u8; 4];
        let huge = u64::MAX - 1;
        assert_eq!(s.read(huge, &mut buf), Err(Error::ShortRead));
        assert_eq!(s.write(huge, b"data"), Err(Error::StorageFailure));
        // Addressable, but far more than any allocator will give: "disk full".
        // (This is the Rust form of Zig's test with a failing allocator.)
        assert_eq!(s.write(1 << 60, b"data"), Err(Error::StorageFailure));
        assert_eq!(s.size(), Ok(4)); // nothing changed
    }

    #[test]
    fn file_storage_create_write_reopen_read() {
        let tmp = TempDir::new("file_storage");
        let path = tmp.0.join("s.bin");
        {
            let mut s = FileStorage::create(&path).unwrap();
            s.write(0, b"hello").unwrap();
            s.write(4096, b"page one").unwrap();
            s.sync().unwrap();
            assert_eq!(s.size(), Ok(4096 + 8));
        }

        let mut s = FileStorage::open(&path).unwrap();
        let mut buf = [0u8; 8];
        s.read(4096, &mut buf).unwrap();
        assert_eq!(&buf, b"page one");
        s.read(5, &mut buf[..3]).unwrap(); // the gap reads as zeroes
        assert_eq!(&buf[..3], b"\0\0\0");
        assert_eq!(s.read(4100, &mut buf), Err(Error::ShortRead));
        let missing = FileStorage::open(tmp.0.join("missing.bin")).unwrap_err();
        assert_eq!(missing.kind(), io::ErrorKind::NotFound);
    }
}
