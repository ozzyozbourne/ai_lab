//! adapter.zig: chapter 12's storage interface on top of chapter 21's.
//!
//! The two chapters grew different interfaces for "the disk":
//!
//!   chapter 12 (base_storage.zig)        chapter 21 (base_page_storage.zig)
//!   read(offset, buffer)                 readPage(page_no, *Page)
//!   write(offset, bytes)                 writePage(page_no, *const Page)
//!   size() in bytes, may fail            size() in pages, never fails
//!   sync()                               sync()
//!   errors: ShortRead, StorageFailure    errors: PowerLoss, OutOfBounds,
//!                                                OutOfMemory, InputOutput
//!
//! The pager, the buffer pool and the tree are written against the left one;
//! `SimDisk` implements the right one. The pager only ever reads and writes
//! whole pages at page-aligned offsets, so the left interface can be served
//! by the right one with one division. That is all `PageFile` does.
//!
//! Error mapping (the left interface has only two errors):
//!   OutOfBounds on a read    -> ShortRead (the page is past the end)
//!   everything else          -> StorageFailure
//! A caller that must know whether the power went off asks the machine.
//!
//! This chapter has two implementations of the left interface over the right:
//!   `PageFile` (here)   no log, no checksums: chapter 12's behaviour on a
//!                       disk that can lose power. The "before" picture.
//!   `Wal` (wal.zig)     the write-ahead log in front of the main file.
const std = @import("std");
const byte_storage = @import("base_storage.zig");
const ByteStorage = byte_storage.Storage;
const page_storage = @import("base_page_storage.zig");
const PageStorage = page_storage.Storage;
const Page = page_storage.Page;
pub const page_size = page_storage.page_size;

/// The page number of a whole-page request, or null if the request is not
/// one whole page at a page boundary (the pager never issues such a request).
pub fn wholePage(offset: u64, len: usize) ?u64 {
    if (len != page_size or offset % page_size != 0) return null;
    return offset / page_size;
}

pub const PageFile = struct {
    inner: PageStorage,

    /// The interface value. `self` must outlive it and must not move.
    pub fn storage(self: *PageFile) ByteStorage {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: ByteStorage.VTable = .{ .read = read, .write = write, .size = size, .sync = sync };

    fn read(ptr: *anyopaque, offset: u64, buffer: []u8) ByteStorage.Error!void {
        const self: *PageFile = @ptrCast(@alignCast(ptr));
        const page_no = wholePage(offset, buffer.len) orelse return error.StorageFailure;
        self.inner.readPage(page_no, buffer[0..page_size]) catch |err| return switch (err) {
            error.OutOfBounds => error.ShortRead,
            else => error.StorageFailure,
        };
    }

    fn write(ptr: *anyopaque, offset: u64, bytes: []const u8) ByteStorage.Error!void {
        const self: *PageFile = @ptrCast(@alignCast(ptr));
        const page_no = wholePage(offset, bytes.len) orelse return error.StorageFailure;
        self.inner.writePage(page_no, bytes[0..page_size]) catch return error.StorageFailure;
    }

    fn size(ptr: *anyopaque) ByteStorage.Error!u64 {
        const self: *PageFile = @ptrCast(@alignCast(ptr));
        return self.inner.size() * page_size;
    }

    fn sync(ptr: *anyopaque) ByteStorage.Error!void {
        const self: *PageFile = @ptrCast(@alignCast(ptr));
        self.inner.sync() catch return error.StorageFailure;
    }
};

// ---------------------------------------------------------------------------
const testing = std.testing;
const SimDisk = @import("base_sim_disk.zig").SimDisk;
const Pager = @import("base_pager.zig").Pager;

test "PageFile: the pager of chapter 12 runs on the SimDisk of chapter 21" {
    var disk: SimDisk = .init(testing.allocator, 1);
    defer disk.deinit();
    var file: PageFile = .{ .inner = disk.storage() };
    var pager: Pager = try .init(file.storage());
    try testing.expectEqual(0, pager.pageCount());

    const id = try pager.allocatePage();
    var page: Page = @splat(0);
    @memcpy(page[0..5], "hello");
    try pager.writePage(id, &page);
    var out: Page = undefined;
    try pager.readPage(id, &out);
    try testing.expectEqualSlices(u8, &page, &out);
    try testing.expectEqual(page_size, try file.storage().size());
    try testing.expectEqual(1, disk.pendingCount() - 1); // allocation + write, both unsynced
    try pager.sync();
    try testing.expectEqual(0, disk.pendingCount());
}

test "PageFile: error mapping and whole-page requests only" {
    var disk: SimDisk = .init(testing.allocator, 1);
    defer disk.deinit();
    var file: PageFile = .{ .inner = disk.storage() };
    const s = file.storage();
    var page: Page = @splat(7);
    try testing.expectError(error.ShortRead, s.read(0, &page)); // past the end
    try testing.expectError(error.StorageFailure, s.read(0, page[0..100])); // not a whole page
    try testing.expectError(error.StorageFailure, s.write(12, &page)); // not page-aligned
    try s.write(0, &page);
    disk.powerOffAfterWrites(0);
    try testing.expectError(error.StorageFailure, s.read(0, &page)); // PowerLoss
    try testing.expectError(error.StorageFailure, s.write(0, &page));
    try testing.expectError(error.StorageFailure, s.sync());
    try testing.expectEqual(page_size, try s.size()); // size still answers
}
