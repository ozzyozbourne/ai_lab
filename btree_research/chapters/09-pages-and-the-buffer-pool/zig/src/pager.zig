//! pager.zig: a file seen as an array of fixed-size pages.
//!
//! Page `id` lives at byte offset `id * page_size`. That one multiplication
//! is the whole address translation, and it is why a page id can be used as a
//! pointer that stays valid across restarts.
//!
//! The pager does no caching: every `readPage` and `writePage` goes to the
//! storage. Caching is the buffer pool's job (buffer_pool.zig). The pager
//! counts its calls so that tests and the demo can show how many of them the
//! buffer pool saves.
const std = @import("std");
const testing = std.testing;
const storage_mod = @import("storage.zig");
const Storage = storage_mod.Storage;

pub const page_size = 4096;
pub const Page = [page_size]u8;

/// A page number. 32 bits address 2^32 pages = 16 TiB of 4 KiB pages.
pub const PageId = u32;
/// "No page", the on-disk equivalent of a null pointer.
pub const invalid_page_id: PageId = std.math.maxInt(PageId);

pub const Pager = struct {
    storage: Storage,
    /// Pages 0 .. page_count-1 exist. Kept in memory; equals size / page_size.
    page_count: PageId,
    stats: Stats = .{},

    pub const Stats = struct {
        reads: u64 = 0,
        writes: u64 = 0,
        allocations: u64 = 0,
        syncs: u64 = 0,
    };

    pub const Error = Storage.Error || error{
        /// The storage size is not a whole number of pages, or it holds more
        /// pages than a 32-bit page id can number.
        CorruptFile,
        /// `allocatePage` when every page id is in use. The file is not
        /// damaged, it is full.
        FileFull,
        /// The page id is >= page_count.
        PageOutOfRange,
    };

    /// Wrap a storage. An empty storage is a new database with zero pages; a
    /// non-empty one must be a whole number of pages. To create or open a
    /// file, make a `FileStorage` with `.create` / `.open` and pass its
    /// `storage()` here.
    pub fn init(storage: Storage) Error!Pager {
        const size = try storage.size();
        if (size % page_size != 0) return error.CorruptFile;
        const count = size / page_size;
        if (count >= invalid_page_id) return error.CorruptFile;
        return .{ .storage = storage, .page_count = @intCast(count) };
    }

    pub fn pageCount(self: *const Pager) PageId {
        return self.page_count;
    }

    /// Append one zero-filled page and return its id. This is the only way
    /// the file grows, so the size stays a multiple of `page_size`.
    /// (Reusing freed pages is chapter 13.)
    pub fn allocatePage(self: *Pager) Error!PageId {
        const id = self.page_count;
        // invalid_page_id must never name a real page, so the last usable id
        // is invalid_page_id - 1 and the largest page count is the same number.
        if (id == invalid_page_id - 1) return error.FileFull;
        const zero: Page = @splat(0);
        try self.storage.write(offsetOf(id), &zero);
        // Count the page only after the write succeeded.
        self.page_count = id + 1;
        self.stats.allocations += 1;
        return id;
    }

    pub fn readPage(self: *Pager, id: PageId, out: *Page) Error!void {
        if (id >= self.page_count) return error.PageOutOfRange;
        try self.storage.read(offsetOf(id), out);
        self.stats.reads += 1;
    }

    pub fn writePage(self: *Pager, id: PageId, page: *const Page) Error!void {
        if (id >= self.page_count) return error.PageOutOfRange;
        try self.storage.write(offsetOf(id), page);
        self.stats.writes += 1;
    }

    pub fn sync(self: *Pager) Error!void {
        try self.storage.sync();
        self.stats.syncs += 1;
    }

    /// Byte offset of a page: the entire "pointer dereference" of a page id.
    pub fn offsetOf(id: PageId) u64 {
        return @as(u64, id) * page_size;
    }
};

test "Pager: allocate, write, read" {
    var mem: storage_mod.MemStorage = .init(testing.allocator);
    defer mem.deinit();
    var pager: Pager = try .init(mem.storage());
    try testing.expectEqual(0, pager.pageCount());

    try testing.expectEqual(0, try pager.allocatePage());
    try testing.expectEqual(1, try pager.allocatePage());
    try testing.expectEqual(2, pager.pageCount());
    try testing.expectEqual(2 * page_size, mem.bytes.items.len);

    var page: Page = @splat(0);
    @memcpy(page[0..5], "hello");
    try pager.writePage(1, &page);

    var out: Page = undefined;
    try pager.readPage(1, &out);
    try testing.expectEqualSlices(u8, &page, &out);
    try pager.readPage(0, &out); // a fresh page is all zeroes
    try testing.expect(std.mem.allEqual(u8, &out, 0));
    // Page 1 starts exactly one page into the storage.
    try testing.expectEqualSlices(u8, "hello", mem.bytes.items[page_size..][0..5]);

    try pager.sync();
    try testing.expectEqual(Pager.Stats{ .reads = 2, .writes = 1, .allocations = 2, .syncs = 1 }, pager.stats);
}

test "Pager: page ids out of range are rejected" {
    var mem: storage_mod.MemStorage = .init(testing.allocator);
    defer mem.deinit();
    var pager: Pager = try .init(mem.storage());
    _ = try pager.allocatePage();

    var page: Page = @splat(0);
    try testing.expectError(error.PageOutOfRange, pager.readPage(1, &page));
    try testing.expectError(error.PageOutOfRange, pager.writePage(1, &page));
    try testing.expectError(error.PageOutOfRange, pager.readPage(invalid_page_id, &page));
    try testing.expectEqual(1, pager.pageCount()); // a rejected write must not grow the file
}

test "Pager: a size that is not a whole number of pages is corrupt" {
    var mem: storage_mod.MemStorage = .init(testing.allocator);
    defer mem.deinit();
    try mem.storage().write(0, "not a page");
    try testing.expectError(error.CorruptFile, Pager.init(mem.storage()));
}

test "Pager: a failed allocation does not change the page count" {
    var mem: storage_mod.MemStorage = .init(testing.allocator);
    defer mem.deinit();
    var pager: Pager = try .init(mem.storage());
    mem.writes_before_failure = 0;
    try testing.expectError(error.StorageFailure, pager.allocatePage());
    try testing.expectEqual(0, pager.pageCount());
    try testing.expectEqual(0, pager.stats.allocations);
}

test "Pager: running out of page ids is FileFull, and nothing is written" {
    var mem: storage_mod.MemStorage = .init(testing.allocator);
    defer mem.deinit();
    var pager: Pager = try .init(mem.storage());
    // A 16 TiB file is out of reach for a test; pretend the pages exist.
    pager.page_count = invalid_page_id - 1;
    try testing.expectError(error.FileFull, pager.allocatePage());
    try testing.expectEqual(invalid_page_id - 1, pager.pageCount());
    try testing.expectEqual(0, pager.stats.allocations);
    try testing.expectEqual(0, mem.bytes.items.len);
}

test "Pager: pages survive closing and reopening a real file" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        var file: storage_mod.FileStorage = try .create(io, tmp.dir, "pager.db");
        defer file.close();
        var pager: Pager = try .init(file.storage());
        var page: Page = @splat(0);
        for (0..3) |i| {
            const id = try pager.allocatePage();
            std.mem.writeInt(u32, page[0..4], @as(u32, @intCast(i)) + 100, .little);
            try pager.writePage(id, &page);
        }
        try pager.sync();
    }

    var file: storage_mod.FileStorage = try .open(io, tmp.dir, "pager.db");
    defer file.close();
    var pager: Pager = try .init(file.storage());
    try testing.expectEqual(3, pager.pageCount());
    var page: Page = undefined;
    try pager.readPage(2, &page);
    try testing.expectEqual(102, std.mem.readInt(u32, page[0..4], .little));
}
