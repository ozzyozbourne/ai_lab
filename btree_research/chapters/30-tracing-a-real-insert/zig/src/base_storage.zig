// Copied from chapters/12-disk-backed-bplus-tree/zig/src/base_storage.zig, which has it from:
// Copied from chapters/09-pages-and-the-buffer-pool/zig/src/storage.zig; behaviour unchanged (only the
// @import paths were renamed to the base_* files of this chapter).
//! storage.zig: the "disk" underneath the pager, as a small interface.
//!
//! A `Storage` is a growable array of bytes with four operations: read at an
//! offset, write at an offset, report the size, and sync. It knows nothing
//! about pages. Keeping it this small is what lets later chapters swap the
//! real file for an in-memory disk (tests) or a simulated disk that tears and
//! drops writes (crash testing) without touching the pager or the buffer pool.
//!
//! The interface has the same shape as `std.mem.Allocator`: a type-erased
//! pointer plus a table of function pointers, passed by value.
//!
//! Two implementations live here:
//!   * `FileStorage`: a real file, positional I/O (pread / pwrite / fsync).
//!   * `MemStorage`:  a byte array, with optional injected read and write
//!                    failures.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const testing = std.testing;

pub const Storage = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    /// Function pointers need one concrete error set, so every backend maps
    /// its own failures onto these two.
    ///   ShortRead:      the read range extends past the end of the storage.
    ///   StorageFailure: the device (or the injected fault) refused the call.
    pub const Error = error{ ShortRead, StorageFailure };

    pub const VTable = struct {
        read: *const fn (ptr: *anyopaque, offset: u64, buffer: []u8) Error!void,
        write: *const fn (ptr: *anyopaque, offset: u64, bytes: []const u8) Error!void,
        size: *const fn (ptr: *anyopaque) Error!u64,
        sync: *const fn (ptr: *anyopaque) Error!void,
    };

    /// Fill `buffer` completely from `offset`, or fail with `ShortRead`.
    pub fn read(self: Storage, offset: u64, buffer: []u8) Error!void {
        return self.vtable.read(self.ptr, offset, buffer);
    }

    /// Write all of `bytes` at `offset`. Writing at or past the end grows the
    /// storage; a gap is filled with zero bytes.
    pub fn write(self: Storage, offset: u64, bytes: []const u8) Error!void {
        return self.vtable.write(self.ptr, offset, bytes);
    }

    /// Current size in bytes.
    pub fn size(self: Storage) Error!u64 {
        return self.vtable.size(self.ptr);
    }

    /// Ask for everything written so far to be made durable (fsync). What that
    /// really guarantees is the subject of chapter 21.
    pub fn sync(self: Storage) Error!void {
        return self.vtable.sync(self.ptr);
    }
};

/// A real file. The caller keeps the `FileStorage` alive (and at a stable
/// address) for as long as any `Storage` made from it is in use.
pub const FileStorage = struct {
    io: Io,
    file: Io.File,

    /// Create a new, empty file (an existing file is truncated).
    pub fn create(io: Io, dir: Io.Dir, sub_path: []const u8) Io.File.OpenError!FileStorage {
        // The defaults are write-only; a database file must be readable too.
        const file = try dir.createFile(io, sub_path, .{ .read = true, .truncate = true });
        return .{ .io = io, .file = file };
    }

    /// Open an existing file for reading and writing; `FileNotFound` if absent.
    pub fn open(io: Io, dir: Io.Dir, sub_path: []const u8) Io.File.OpenError!FileStorage {
        const file = try dir.openFile(io, sub_path, .{ .mode = .read_write });
        return .{ .io = io, .file = file };
    }

    pub fn close(self: *FileStorage) void {
        self.file.close(self.io);
        self.* = undefined;
    }

    pub fn storage(self: *FileStorage) Storage {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: Storage.VTable = .{ .read = read, .write = write, .size = size, .sync = sync };

    fn read(ptr: *anyopaque, offset: u64, buffer: []u8) Storage.Error!void {
        const self: *FileStorage = @ptrCast(@alignCast(ptr));
        // readPositionalAll loops over pread; fewer bytes than asked means EOF.
        const n = self.file.readPositionalAll(self.io, buffer, offset) catch return error.StorageFailure;
        if (n != buffer.len) return error.ShortRead;
    }

    fn write(ptr: *anyopaque, offset: u64, bytes: []const u8) Storage.Error!void {
        const self: *FileStorage = @ptrCast(@alignCast(ptr));
        // pwrite past the end extends the file; the OS zero-fills any gap.
        self.file.writePositionalAll(self.io, bytes, offset) catch return error.StorageFailure;
    }

    fn size(ptr: *anyopaque) Storage.Error!u64 {
        const self: *FileStorage = @ptrCast(@alignCast(ptr));
        return self.file.length(self.io) catch return error.StorageFailure;
    }

    fn sync(ptr: *anyopaque) Storage.Error!void {
        const self: *FileStorage = @ptrCast(@alignCast(ptr));
        self.file.sync(self.io) catch return error.StorageFailure;
    }
};

/// A disk made of memory. Used by tests and by the workload part of the demo,
/// and the starting point for the simulated disk of chapter 21.
pub const MemStorage = struct {
    allocator: Allocator,
    bytes: std.ArrayList(u8) = .empty,
    /// Fault injection: when set, this many more writes succeed and every
    /// write after that fails with `StorageFailure`. `null` = never fail.
    writes_before_failure: ?u64 = null,
    /// The same countdown for reads.
    reads_before_failure: ?u64 = null,
    sync_count: u64 = 0,

    pub fn init(allocator: Allocator) MemStorage {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *MemStorage) void {
        self.bytes.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn storage(self: *MemStorage) Storage {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: Storage.VTable = .{ .read = read, .write = write, .size = size, .sync = sync };

    fn read(ptr: *anyopaque, offset: u64, buffer: []u8) Storage.Error!void {
        const self: *MemStorage = @ptrCast(@alignCast(ptr));
        if (self.reads_before_failure) |*left| {
            if (left.* == 0) return error.StorageFailure;
            left.* -= 1;
        }
        // An offset so large that the end does not fit in 64 bits is past
        // the end of any storage.
        const end = std.math.add(u64, offset, buffer.len) catch return error.ShortRead;
        if (end > self.bytes.items.len) return error.ShortRead;
        @memcpy(buffer, self.bytes.items[@intCast(offset)..@intCast(end)]);
    }

    fn write(ptr: *anyopaque, offset: u64, bytes: []const u8) Storage.Error!void {
        const self: *MemStorage = @ptrCast(@alignCast(ptr));
        if (self.writes_before_failure) |*left| {
            if (left.* == 0) return error.StorageFailure;
            left.* -= 1;
        }
        // A range that cannot be addressed is a range the "disk" cannot hold.
        const end_u64 = std.math.add(u64, offset, bytes.len) catch return error.StorageFailure;
        const end = std.math.cast(usize, end_u64) orelse return error.StorageFailure;
        if (end > self.bytes.items.len) {
            // Grow like a file does: new bytes read back as zero. Running out
            // of memory here plays the role of "disk full".
            const old_len = self.bytes.items.len;
            self.bytes.resize(self.allocator, end) catch return error.StorageFailure;
            @memset(self.bytes.items[old_len..], 0);
        }
        @memcpy(self.bytes.items[@intCast(offset)..end], bytes);
    }

    fn size(ptr: *anyopaque) Storage.Error!u64 {
        const self: *MemStorage = @ptrCast(@alignCast(ptr));
        return self.bytes.items.len;
    }

    fn sync(ptr: *anyopaque) Storage.Error!void {
        const self: *MemStorage = @ptrCast(@alignCast(ptr));
        self.sync_count += 1; // memory has nothing to flush; just count the call
    }
};

test "MemStorage: write, read back, grow with a zero-filled gap, short read" {
    var mem: MemStorage = .init(testing.allocator);
    defer mem.deinit();
    const s = mem.storage();

    try testing.expectEqual(0, try s.size());
    try s.write(0, "abcd");
    try s.write(8, "xy"); // leaves a gap at 4..8
    try testing.expectEqual(10, try s.size());

    var buf: [10]u8 = undefined;
    try s.read(0, &buf);
    try testing.expectEqualSlices(u8, "abcd\x00\x00\x00\x00xy", &buf);
    try testing.expectError(error.ShortRead, s.read(4, &buf));
    try s.sync();
    try testing.expectEqual(1, mem.sync_count);
}

test "MemStorage: injected write failure" {
    var mem: MemStorage = .init(testing.allocator);
    defer mem.deinit();
    const s = mem.storage();

    mem.writes_before_failure = 1;
    try s.write(0, "ok");
    try testing.expectError(error.StorageFailure, s.write(0, "no"));
    var buf: [2]u8 = undefined;
    try s.read(0, &buf);
    try testing.expectEqualSlices(u8, "ok", &buf); // the failed write changed nothing
    mem.writes_before_failure = null;
    try s.write(0, "go");
}

test "MemStorage: injected read failure" {
    var mem: MemStorage = .init(testing.allocator);
    defer mem.deinit();
    const s = mem.storage();
    try s.write(0, "data");

    var buf: [4]u8 = @splat('.');
    mem.reads_before_failure = 1;
    try s.read(0, &buf);
    try testing.expectEqualSlices(u8, "data", &buf);
    @memset(&buf, '.');
    try testing.expectError(error.StorageFailure, s.read(0, &buf));
    try testing.expectEqualSlices(u8, "....", &buf); // the failed read filled nothing
    mem.reads_before_failure = null;
    try s.read(0, &buf);
    try testing.expectEqualSlices(u8, "data", &buf);
}

test "MemStorage: offsets near the end of the address space are errors, not overflows" {
    var mem: MemStorage = .init(testing.allocator);
    defer mem.deinit();
    const s = mem.storage();
    try s.write(0, "data");
    var buf: [4]u8 = undefined;
    const huge = std.math.maxInt(u64) - 1;
    try testing.expectError(error.ShortRead, s.read(huge, &buf));
    try testing.expectError(error.StorageFailure, s.write(huge, "data"));
    // Addressable, but far more than any allocator will give: "disk full".
    try testing.expectError(error.StorageFailure, s.write(1 << 60, "data"));
    try testing.expectEqual(4, try s.size()); // nothing changed
}

test "MemStorage: running out of memory is reported as StorageFailure" {
    var failing: testing.FailingAllocator = .init(testing.allocator, .{ .fail_index = 0 });
    var mem: MemStorage = .init(failing.allocator());
    defer mem.deinit();
    try testing.expectError(error.StorageFailure, mem.storage().write(0, "x"));
    try testing.expectEqual(0, try mem.storage().size());
}

test "FileStorage: create, write, reopen, read" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        var file: FileStorage = try .create(io, tmp.dir, "s.bin");
        defer file.close();
        const s = file.storage();
        try s.write(0, "hello");
        try s.write(4096, "page one");
        try s.sync();
        try testing.expectEqual(4096 + 8, try s.size());
    }

    var file: FileStorage = try .open(io, tmp.dir, "s.bin");
    defer file.close();
    const s = file.storage();
    var buf: [8]u8 = undefined;
    try s.read(4096, &buf);
    try testing.expectEqualSlices(u8, "page one", &buf);
    try s.read(5, buf[0..3]); // the gap reads as zeroes
    try testing.expectEqualSlices(u8, "\x00\x00\x00", buf[0..3]);
    try testing.expectError(error.ShortRead, s.read(4100, &buf));
    try testing.expectError(error.FileNotFound, FileStorage.open(io, tmp.dir, "missing.bin"));
}
