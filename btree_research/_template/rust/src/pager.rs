//! Fixed-size page file using positional I/O (`pread`/`pwrite`) from
//! `std::os::unix::fs::FileExt`: no shared seek cursor, `&self` methods.

use std::fs::{File, OpenOptions};
use std::io;
use std::os::unix::fs::FileExt;
use std::path::Path;

pub const PAGE_SIZE: usize = 4096;
pub type Page = [u8; PAGE_SIZE];

#[derive(Debug)]
pub struct Pager {
    file: File,
    page_count: u64,
}

impl Pager {
    /// Opens (creating if missing) a page file for reading and writing.
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

    pub fn page_count(&self) -> u64 {
        self.page_count
    }

    /// `read_exact_at` = loop over `pread` until the buffer is full
    /// (`UnexpectedEof` if the page does not exist).
    pub fn read_page(&self, page_no: u64, out: &mut Page) -> io::Result<()> {
        self.file.read_exact_at(out, page_no * PAGE_SIZE as u64)
    }

    /// `write_all_at` = loop over `pwrite`; extends the file if needed.
    pub fn write_page(&mut self, page_no: u64, page: &Page) -> io::Result<()> {
        self.file.write_all_at(page, page_no * PAGE_SIZE as u64)?;
        self.page_count = self.page_count.max(page_no + 1);
        Ok(())
    }

    pub fn alloc_page(&mut self) -> io::Result<u64> {
        let page_no = self.page_count;
        self.write_page(page_no, &[0; PAGE_SIZE])?;
        Ok(page_no)
    }

    /// fsync (data + metadata). `sync_data` is fdatasync.
    pub fn sync(&self) -> io::Result<()> {
        self.file.sync_all()
    }
}

/// Little-endian field access inside a page, without `unsafe`.
pub fn read_u32(page: &[u8], offset: usize) -> u32 {
    u32::from_le_bytes(page[offset..offset + 4].try_into().expect("4 bytes"))
}

pub fn write_u32(page: &mut [u8], offset: usize, value: u32) {
    page[offset..offset + 4].copy_from_slice(&value.to_le_bytes());
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn le_fields_and_shifts() {
        let mut page = [0u8; PAGE_SIZE];
        write_u32(&mut page, 8, 0xDEAD_BEEF);
        assert_eq!(page[8..12], [0xEF, 0xBE, 0xAD, 0xDE]);
        assert_eq!(read_u32(&page, 8), 0xDEAD_BEEF);

        // Overlapping move inside one buffer (Zig: @memmove): open a gap at 100..104.
        page.copy_within(100..200, 104);
        // Non-overlapping copy between buffers (Zig: @memcpy).
        let mut other = [0u8; PAGE_SIZE];
        other[..12].copy_from_slice(&page[..12]);
        assert_eq!(read_u32(&other, 8), 0xDEAD_BEEF);
    }
}
