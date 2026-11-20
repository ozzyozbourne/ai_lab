//! adapter.rs: chapter 12's storage trait on top of chapter 21's.
//!
//! The two chapters grew different interfaces for "the disk":
//!
//! ```text
//! chapter 12 (base_storage.rs)         chapter 21 (base_page_storage.rs)
//! read(offset, buffer)                 read_page(page_no, &mut Page)
//! write(offset, bytes)                 write_page(page_no, &Page)
//! size() in bytes, may fail            size() in pages, never fails
//! sync()                               sync()
//! errors: ShortRead, StorageFailure    errors: PowerLoss, OutOfBounds,
//!                                              OutOfMemory, InputOutput
//! ```
//!
//! The pager, the buffer pool and the tree are written against the left one;
//! `SimDisk` implements the right one. The pager only ever reads and writes
//! whole pages at page-aligned offsets, so the left interface can be served
//! by the right one with one division. That is all `PageFile` does.
//!
//! Error mapping (the left interface has only two storage errors):
//!   OutOfBounds on a read    -> ShortRead (the page is past the end)
//!   everything else          -> StorageFailure
//! A caller that must know whether the power went off asks the machine.
//!
//! This chapter has two implementations of the left trait over the right:
//!   `PageFile` (here)   no log, no checksums: chapter 12's behaviour on a
//!                       disk that can lose power. The "before" picture.
//!   `Wal` (wal.rs)      the write-ahead log in front of the main file.

use crate::base_page_storage::{PAGE_SIZE, Page, Storage as PageStorage, StorageError};
use crate::base_storage::{Error, Storage as ByteStorage};

/// The page number of a whole-page request, or None if the request is not
/// one whole page at a page boundary (the pager never issues such a request).
pub fn whole_page(offset: u64, len: usize) -> Option<u64> {
    if len != PAGE_SIZE || offset % PAGE_SIZE as u64 != 0 {
        return None;
    }
    Some(offset / PAGE_SIZE as u64)
}

pub struct PageFile {
    pub inner: Box<dyn PageStorage>,
}

impl ByteStorage for PageFile {
    fn read(&mut self, offset: u64, buffer: &mut [u8]) -> Result<(), Error> {
        let page_no = whole_page(offset, buffer.len()).ok_or(Error::StorageFailure)?;
        let out: &mut Page = buffer.try_into().expect("a whole page");
        self.inner.read_page(page_no, out).map_err(|err| match err {
            StorageError::OutOfBounds => Error::ShortRead,
            _ => Error::StorageFailure,
        })
    }

    fn write(&mut self, offset: u64, bytes: &[u8]) -> Result<(), Error> {
        let page_no = whole_page(offset, bytes.len()).ok_or(Error::StorageFailure)?;
        let page: &Page = bytes.try_into().expect("a whole page");
        self.inner.write_page(page_no, page).map_err(|_| Error::StorageFailure)
    }

    fn size(&mut self) -> Result<u64, Error> {
        Ok(self.inner.size() * PAGE_SIZE as u64)
    }

    fn sync(&mut self) -> Result<(), Error> {
        self.inner.sync().map_err(|_| Error::StorageFailure)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::base_pager::Pager;
    use crate::machine::{self, Machine};

    #[test]
    fn page_file_the_pager_of_chapter_12_runs_on_the_sim_disk_of_chapter_21() {
        let m = Machine::new(1);
        let mut pager = Pager::new(Box::new(PageFile { inner: machine::main_storage(&m) })).unwrap();
        assert_eq!(pager.page_count(), 0);

        let id = pager.allocate_page().unwrap();
        let mut page = [0u8; PAGE_SIZE];
        page[..5].copy_from_slice(b"hello");
        pager.write_page(id, &page).unwrap();
        let mut out = [0u8; PAGE_SIZE];
        pager.read_page(id, &mut out).unwrap();
        assert_eq!(out, page);
        assert_eq!(m.borrow().main.pending_count(), 2); // the allocation and the write, both unsynced
        pager.sync().unwrap();
        assert_eq!(m.borrow().main.pending_count(), 0);
    }

    #[test]
    fn page_file_error_mapping_and_whole_page_requests_only() {
        let m = Machine::new(1);
        let mut s = PageFile { inner: machine::main_storage(&m) };
        let mut page = [7u8; PAGE_SIZE];
        assert_eq!(s.read(0, &mut page), Err(Error::ShortRead)); // past the end
        assert_eq!(s.read(0, &mut page[..100]), Err(Error::StorageFailure)); // not a whole page
        assert_eq!(s.write(12, &page), Err(Error::StorageFailure)); // not page-aligned
        s.write(0, &page).unwrap();
        m.borrow_mut().power_off_after_writes(0);
        assert_eq!(s.read(0, &mut page), Err(Error::StorageFailure)); // PowerLoss
        assert_eq!(s.write(0, &page), Err(Error::StorageFailure));
        assert_eq!(s.sync(), Err(Error::StorageFailure));
        assert_eq!(s.size(), Ok(PAGE_SIZE as u64)); // size still answers
    }
}
