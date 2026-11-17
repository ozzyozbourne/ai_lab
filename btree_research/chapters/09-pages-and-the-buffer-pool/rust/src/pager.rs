//! pager.rs: a file seen as an array of fixed-size pages.
//!
//! Page `id` lives at byte offset `id * PAGE_SIZE`. That one multiplication
//! is the whole address translation, and it is why a page id can be used as a
//! pointer that stays valid across restarts.
//!
//! The pager does no caching: every `read_page` and `write_page` goes to the
//! storage. Caching is the buffer pool's job (buffer_pool.rs). The pager
//! counts its calls so that tests and the demo can show how many of them the
//! buffer pool saves.

use crate::storage::{Error, Storage};

pub const PAGE_SIZE: usize = 4096;
pub type Page = [u8; PAGE_SIZE];

/// A page number. 32 bits address 2^32 pages = 16 TiB of 4 KiB pages.
pub type PageId = u32;
/// "No page", the on-disk equivalent of a null pointer.
pub const INVALID_PAGE_ID: PageId = PageId::MAX;

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct PagerStats {
    pub reads: u64,
    pub writes: u64,
    pub allocations: u64,
    pub syncs: u64,
}

pub struct Pager {
    /// Owned. (Zig's pager holds the by-value `Storage` interface and the
    /// caller keeps the backend alive; here ownership does that job.)
    storage: Box<dyn Storage>,
    /// Pages 0 .. page_count-1 exist. Kept in memory; equals size / PAGE_SIZE.
    page_count: PageId,
    pub stats: PagerStats,
}

impl Pager {
    /// Wrap a storage. An empty storage is a new database with zero pages; a
    /// non-empty one must be a whole number of pages. To create or open a
    /// file, pass `Box::new(FileStorage::create(path)?)` / `open(path)?`.
    pub fn new(mut storage: Box<dyn Storage>) -> Result<Self, Error> {
        let size = storage.size()?;
        if size % PAGE_SIZE as u64 != 0 {
            return Err(Error::CorruptFile);
        }
        let count = size / PAGE_SIZE as u64;
        if count >= u64::from(INVALID_PAGE_ID) {
            return Err(Error::CorruptFile);
        }
        Ok(Self {
            storage,
            page_count: count as PageId,
            stats: PagerStats::default(),
        })
    }

    pub fn page_count(&self) -> PageId {
        self.page_count
    }

    /// Append one zero-filled page and return its id. This is the only way
    /// the file grows, so the size stays a multiple of `PAGE_SIZE`.
    /// (Reusing freed pages is chapter 13.)
    pub fn allocate_page(&mut self) -> Result<PageId, Error> {
        let id = self.page_count;
        // INVALID_PAGE_ID must never name a real page, so the last usable id
        // is INVALID_PAGE_ID - 1 and the largest page count is the same number.
        if id == INVALID_PAGE_ID - 1 {
            return Err(Error::FileFull);
        }
        self.storage.write(Self::offset_of(id), &[0u8; PAGE_SIZE])?;
        // Count the page only after the write succeeded.
        self.page_count = id + 1;
        self.stats.allocations += 1;
        Ok(id)
    }

    pub fn read_page(&mut self, id: PageId, out: &mut Page) -> Result<(), Error> {
        if id >= self.page_count {
            return Err(Error::PageOutOfRange);
        }
        self.storage.read(Self::offset_of(id), out)?;
        self.stats.reads += 1;
        Ok(())
    }

    pub fn write_page(&mut self, id: PageId, page: &Page) -> Result<(), Error> {
        if id >= self.page_count {
            return Err(Error::PageOutOfRange);
        }
        self.storage.write(Self::offset_of(id), page)?;
        self.stats.writes += 1;
        Ok(())
    }

    pub fn sync(&mut self) -> Result<(), Error> {
        self.storage.sync()?;
        self.stats.syncs += 1;
        Ok(())
    }

    /// Byte offset of a page: the entire "pointer dereference" of a page id.
    pub fn offset_of(id: PageId) -> u64 {
        u64::from(id) * PAGE_SIZE as u64
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::TempDir;
    use crate::storage::{FileStorage, MemStorage};

    #[test]
    fn pager_allocate_write_read() {
        let mem = MemStorage::new();
        let mut pager = Pager::new(Box::new(mem.clone())).unwrap();
        assert_eq!(pager.page_count(), 0);

        assert_eq!(pager.allocate_page(), Ok(0));
        assert_eq!(pager.allocate_page(), Ok(1));
        assert_eq!(pager.page_count(), 2);
        assert_eq!(mem.bytes().len(), 2 * PAGE_SIZE);

        let mut page = [0u8; PAGE_SIZE];
        page[..5].copy_from_slice(b"hello");
        pager.write_page(1, &page).unwrap();

        let mut out = [0xAAu8; PAGE_SIZE];
        pager.read_page(1, &mut out).unwrap();
        assert_eq!(page, out);
        pager.read_page(0, &mut out).unwrap(); // a fresh page is all zeroes
        assert!(out.iter().all(|&b| b == 0));
        // Page 1 starts exactly one page into the storage.
        assert_eq!(&mem.bytes()[PAGE_SIZE..PAGE_SIZE + 5], b"hello");

        pager.sync().unwrap();
        let want = PagerStats {
            reads: 2,
            writes: 1,
            allocations: 2,
            syncs: 1,
        };
        assert_eq!(pager.stats, want);
    }

    #[test]
    fn pager_page_ids_out_of_range_are_rejected() {
        let mut pager = Pager::new(Box::new(MemStorage::new())).unwrap();
        pager.allocate_page().unwrap();

        let mut page = [0u8; PAGE_SIZE];
        assert_eq!(pager.read_page(1, &mut page), Err(Error::PageOutOfRange));
        assert_eq!(pager.write_page(1, &page), Err(Error::PageOutOfRange));
        assert_eq!(
            pager.read_page(INVALID_PAGE_ID, &mut page),
            Err(Error::PageOutOfRange)
        );
        assert_eq!(pager.page_count(), 1); // a rejected write must not grow the file
    }

    #[test]
    fn pager_a_size_that_is_not_a_whole_number_of_pages_is_corrupt() {
        let mut mem = MemStorage::new();
        mem.write(0, b"not a page").unwrap();
        assert_eq!(Pager::new(Box::new(mem)).err(), Some(Error::CorruptFile));
    }

    #[test]
    fn pager_a_failed_allocation_does_not_change_the_page_count() {
        let mem = MemStorage::new();
        let mut pager = Pager::new(Box::new(mem.clone())).unwrap();
        mem.set_writes_before_failure(Some(0));
        assert_eq!(pager.allocate_page(), Err(Error::StorageFailure));
        assert_eq!(pager.page_count(), 0);
        assert_eq!(pager.stats.allocations, 0);
    }

    #[test]
    fn pager_running_out_of_page_ids_is_file_full_and_nothing_is_written() {
        let mem = MemStorage::new();
        let mut pager = Pager::new(Box::new(mem.clone())).unwrap();
        // A 16 TiB file is out of reach for a test; pretend the pages exist.
        pager.page_count = INVALID_PAGE_ID - 1;
        assert_eq!(pager.allocate_page(), Err(Error::FileFull));
        assert_eq!(pager.page_count(), INVALID_PAGE_ID - 1);
        assert_eq!(pager.stats.allocations, 0);
        assert!(mem.bytes().is_empty());
    }

    #[test]
    fn pager_pages_survive_closing_and_reopening_a_real_file() {
        let tmp = TempDir::new("pager_reopen");
        let path = tmp.0.join("pager.db");
        {
            let mut pager = Pager::new(Box::new(FileStorage::create(&path).unwrap())).unwrap();
            let mut page = [0u8; PAGE_SIZE];
            for i in 0..3u32 {
                let id = pager.allocate_page().unwrap();
                page[..4].copy_from_slice(&(i + 100).to_le_bytes());
                pager.write_page(id, &page).unwrap();
            }
            pager.sync().unwrap();
        }

        let mut pager = Pager::new(Box::new(FileStorage::open(&path).unwrap())).unwrap();
        assert_eq!(pager.page_count(), 3);
        let mut page = [0u8; PAGE_SIZE];
        pager.read_page(2, &mut page).unwrap();
        assert_eq!(u32::from_le_bytes(page[..4].try_into().unwrap()), 102);
    }
}
