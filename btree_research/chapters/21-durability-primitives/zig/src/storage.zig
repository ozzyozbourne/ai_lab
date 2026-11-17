//! The `Storage` interface: the four things a page store can do.
//!
//!     readPage(page_no, out)   copy one 4096-byte page out of the store
//!     writePage(page_no, page) hand one page to the store (NOT durable yet)
//!     sync()                   make every earlier write durable (fsync)
//!     size()                   number of pages, as seen by this process
//!
//! The whole chapter is about the gap between `writePage` and `sync`. After
//! `writePage` returns, a `readPage` sees the new bytes, but a power cut may
//! still lose them, keep them, or keep only some 512-byte sectors of them.
//! Only after `sync` returns are they guaranteed to survive.
//!
//! Two implementations: `FileStorage` (file_storage.zig, a real file) and
//! `SimDisk` (sim_disk.zig, memory plus simulated crashes). Code written
//! against `Storage` runs unchanged on both; chapter 22 copies this file.
//!
//! Zig has no interface keyword: an interface is a struct holding a type-erased
//! pointer and a table of function pointers, exactly like `std.mem.Allocator`.
const std = @import("std");

pub const page_size = 4096;
/// The unit a disk writes atomically (textbook assumption: a 512-byte sector
/// is either entirely old or entirely new after a power cut).
pub const sector_size = 512;
pub const sectors_per_page = page_size / sector_size; // 8
pub const Page = [page_size]u8;

pub const Storage = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const Error = error{
        /// The simulated machine lost power; nothing works until `SimDisk.crash`.
        PowerLoss,
        /// `readPage` of a page at or beyond `size()`, or a page number too
        /// large for the implementation.
        OutOfBounds,
        /// The implementation could not allocate memory for the write.
        OutOfMemory,
        /// The operating system reported an I/O error (real files only).
        InputOutput,
    };

    pub const VTable = struct {
        readPage: *const fn (ptr: *anyopaque, page_no: u64, out: *Page) Error!void,
        writePage: *const fn (ptr: *anyopaque, page_no: u64, page: *const Page) Error!void,
        sync: *const fn (ptr: *anyopaque) Error!void,
        size: *const fn (ptr: *anyopaque) u64,
    };

    /// Read page `page_no` as this process currently sees it (including
    /// writes that are not durable yet).
    pub fn readPage(self: Storage, page_no: u64, out: *Page) Error!void {
        return self.vtable.readPage(self.ptr, page_no, out);
    }

    /// Replace page `page_no`. Writing at or past `size()` extends the store;
    /// skipped pages read back as zeroes. NOT durable until `sync` returns.
    pub fn writePage(self: Storage, page_no: u64, page: *const Page) Error!void {
        return self.vtable.writePage(self.ptr, page_no, page);
    }

    /// Returns only after every earlier `writePage` is durable.
    pub fn sync(self: Storage) Error!void {
        return self.vtable.sync(self.ptr);
    }

    /// Number of pages (highest written page number + 1).
    pub fn size(self: Storage) u64 {
        return self.vtable.size(self.ptr);
    }
};

test "geometry" {
    try std.testing.expectEqual(8, sectors_per_page);
    try std.testing.expectEqual(page_size, sectors_per_page * sector_size);
}
