// Copied from chapters/21-durability-primitives/rust/src/storage.rs; unchanged.
//! The `Storage` trait: the four things a page store can do.
//!
//! ```text
//! read_page(page_no, out)   copy one 4096-byte page out of the store
//! write_page(page_no, page) hand one page to the store (NOT durable yet)
//! sync()                    make every earlier write durable (fsync)
//! size()                    number of pages, as seen by this process
//! ```
//!
//! The whole chapter is about the gap between `write_page` and `sync`. After
//! `write_page` returns, a `read_page` sees the new bytes, but a power cut may
//! still lose them, keep them, or keep only some 512-byte sectors of them.
//! Only after `sync` returns are they guaranteed to survive.
//!
//! Two implementations: `FileStorage` (file_storage.rs, a real file) and
//! `SimDisk` (sim_disk.rs, memory plus simulated crashes). Code written
//! against `&mut dyn Storage` runs unchanged on both; chapter 22 copies this
//! file.
//!
//! The contract both implementations keep (the test
//! `sim_disk_and_file_storage_answer_every_call_alike` in lib.rs runs one
//! random stream against both):
//!
//! ```text
//! size()      highest page number ever written + 1, counting writes that
//!             are not durable yet. Never fails.
//! read_page   page_no <  size(): the newest write to that page; a page
//!                                below size() that was never written (a
//!                                hole) reads as zeroes
//!             page_no >= size(): OutOfBounds, `out` untouched
//! write_page  page_no >= the implementation's MAX_PAGES: OutOfBounds.
//!             A write refused with OutOfBounds, OutOfMemory or PowerLoss
//!             leaves size() and every page as they were. InputOutput
//!             (FileStorage only: the operating system reported a failure)
//!             is different: part of the page may have reached the file, so
//!             treat that page as torn.
//! PowerLoss   comes before every other check: on a powered-off SimDisk
//!             read_page, write_page and sync return it whatever the page
//!             number. (size() still answers, with the last value.)
//! ```
//!
//! Where Zig builds the interface by hand (pointer + table of function
//! pointers), Rust has it in the language: `dyn Storage` is exactly that pair.

pub const PAGE_SIZE: usize = 4096;
/// The unit a disk writes atomically (textbook assumption: a 512-byte sector
/// is either entirely old or entirely new after a power cut).
pub const SECTOR_SIZE: usize = 512;
pub const SECTORS_PER_PAGE: usize = PAGE_SIZE / SECTOR_SIZE; // 8
pub type Page = [u8; PAGE_SIZE];

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StorageError {
    /// The simulated machine lost power; nothing works until `SimDisk::crash`.
    PowerLoss,
    /// `read_page` of a page at or beyond `size()`, or `write_page` of a
    /// page number at or beyond the implementation's `MAX_PAGES`.
    OutOfBounds,
    /// The implementation could not hold the write in memory.
    OutOfMemory,
    /// The operating system reported an I/O error (real files only).
    InputOutput,
}

pub trait Storage {
    /// Read page `page_no` as this process currently sees it (including
    /// writes that are not durable yet). A hole below `size()` is zeroes;
    /// at or beyond `size()` the result is `OutOfBounds`.
    fn read_page(&mut self, page_no: u64, out: &mut Page) -> Result<(), StorageError>;

    /// Replace page `page_no`. Writing at or past `size()` extends the store;
    /// skipped pages read back as zeroes. NOT durable until `sync` returns.
    fn write_page(&mut self, page_no: u64, page: &Page) -> Result<(), StorageError>;

    /// Returns only after every earlier `write_page` is durable.
    fn sync(&mut self) -> Result<(), StorageError>;

    /// Number of pages (highest written page number + 1).
    fn size(&self) -> u64;
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn geometry() {
        assert_eq!(SECTORS_PER_PAGE, 8);
        assert_eq!(PAGE_SIZE, SECTORS_PER_PAGE * SECTOR_SIZE);
    }
}
