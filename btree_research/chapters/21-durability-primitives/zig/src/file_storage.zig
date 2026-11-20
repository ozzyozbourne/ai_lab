//! `FileStorage`: the `Storage` interface over a real file.
//!
//! `writePage` is pwrite(2): the bytes land in the operating system's page
//! cache and the call returns. `sync` is fsync(2): the kernel pushes the cached
//! pages to the device and asks the device to flush its own volatile cache. We
//! cannot cut the power in a unit test, which is why `SimDisk` exists; this
//! file is here so the same code can be pointed at a real disk.
const std = @import("std");
const Io = std.Io;
const storage_mod = @import("storage.zig");
const Storage = storage_mod.Storage;
const Page = storage_mod.Page;
const page_size = storage_mod.page_size;

pub const FileStorage = struct {
    io: Io,
    file: Io.File,
    /// Cached so that `size()` cannot fail; the file is ours alone.
    page_count: u64,

    /// Largest page number + 1 this implementation accepts: byte offsets in
    /// a file are signed 64-bit numbers.
    pub const max_pages = (1 << 63) / page_size;

    pub const OpenError = error{NotWholePages} || Io.File.OpenError || Io.File.LengthError;

    /// Create or open `sub_path` in `dir` for reading and writing, keeping
    /// existing contents. The file must be a whole number of pages.
    pub fn open(io: Io, dir: Io.Dir, sub_path: []const u8) OpenError!FileStorage {
        const file = try dir.createFile(io, sub_path, .{ .read = true, .truncate = false });
        errdefer file.close(io);
        const len = try file.length(io);
        if (len % page_size != 0) return error.NotWholePages;
        return .{ .io = io, .file = file, .page_count = len / page_size };
    }

    pub fn close(self: *FileStorage) void {
        self.file.close(self.io);
        self.* = undefined;
    }

    /// The interface value. `self` must outlive it and must not move.
    pub fn storage(self: *FileStorage) Storage {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: Storage.VTable = .{
        .readPage = readPage,
        .writePage = writePage,
        .sync = sync,
        .size = size,
    };

    fn readPage(ptr: *anyopaque, page_no: u64, out: *Page) Storage.Error!void {
        const self: *FileStorage = @ptrCast(@alignCast(ptr));
        if (page_no >= self.page_count) return error.OutOfBounds;
        const n = self.file.readPositionalAll(self.io, out, page_no * page_size) catch
            return error.InputOutput;
        if (n != page_size) return error.InputOutput;
    }

    fn writePage(ptr: *anyopaque, page_no: u64, page: *const Page) Storage.Error!void {
        const self: *FileStorage = @ptrCast(@alignCast(ptr));
        if (page_no >= max_pages) return error.OutOfBounds;
        // A write past the end leaves a hole that the file system reads back
        // as zeroes: the same behaviour SimDisk implements by hand.
        self.file.writePositionalAll(self.io, page, page_no * page_size) catch
            return error.InputOutput;
        self.page_count = @max(self.page_count, page_no + 1);
    }

    fn sync(ptr: *anyopaque) Storage.Error!void {
        const self: *FileStorage = @ptrCast(@alignCast(ptr));
        // If fsync fails, the kernel may already have dropped the dirty pages:
        // retrying and getting "success" proves nothing. The only safe reaction
        // is to stop and recover from the log (chapter 22), so we report it.
        self.file.sync(self.io) catch return error.InputOutput;
    }

    fn size(ptr: *anyopaque) u64 {
        const self: *FileStorage = @ptrCast(@alignCast(ptr));
        return self.page_count;
    }
};

test "FileStorage: write, sync, reopen, read back" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var page: Page = @splat(0);
    {
        var fs: FileStorage = try .open(io, tmp.dir, "data.db");
        defer fs.close();
        const s = fs.storage();
        try testing.expectEqual(0, s.size());
        try testing.expectError(error.OutOfBounds, s.readPage(0, &page));

        @memset(&page, 'A');
        try s.writePage(2, &page); // pages 0 and 1 become a zero-filled hole
        try s.sync();
        try testing.expectEqual(3, s.size());
    }

    var fs: FileStorage = try .open(io, tmp.dir, "data.db");
    defer fs.close();
    const s = fs.storage();
    try testing.expectEqual(3, s.size());
    try s.readPage(2, &page);
    try testing.expect(std.mem.allEqual(u8, &page, 'A'));
    try s.readPage(1, &page);
    try testing.expect(std.mem.allEqual(u8, &page, 0));
}

test "FileStorage: a hole below an unsynced write reads as zeroes" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var fs: FileStorage = try .open(testing.io, tmp.dir, "hole.db");
    defer fs.close();
    const s = fs.storage();
    var page: Page = @splat('A');
    try s.writePage(2, &page); // no sync
    try testing.expectEqual(3, s.size());
    try s.readPage(1, &page);
    try testing.expect(std.mem.allEqual(u8, &page, 0));
    try testing.expectError(error.OutOfBounds, s.readPage(3, &page));
}

test "FileStorage: a page number that does not fit a file offset is refused" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var fs: FileStorage = try .open(testing.io, tmp.dir, "big.db");
    defer fs.close();
    const s = fs.storage();
    const page: Page = @splat('A');
    try testing.expectError(error.OutOfBounds, s.writePage(FileStorage.max_pages, &page));
    try testing.expectError(error.OutOfBounds, s.writePage(std.math.maxInt(u64), &page));
    try testing.expectEqual(0, s.size());
}

test "FileStorage: a file that is not whole pages is rejected" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "bad.db", .data = "short" });
    try testing.expectError(error.NotWholePages, FileStorage.open(testing.io, tmp.dir, "bad.db"));
}
