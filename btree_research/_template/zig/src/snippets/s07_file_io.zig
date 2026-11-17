//! Section 7: file I/O for a pager. In 0.17.1 files live in std.Io
//! (std.Io.File / std.Io.Dir); every operation takes an `io: std.Io`.
//! In tests use `std.testing.io`; in main use `init.io`.
const std = @import("std");
const Io = std.Io;
const testing = std.testing;

pub const page_size = 4096;
pub const Page = [page_size]u8;

/// Minimal pager: fixed-size pages addressed by page number.
pub const Pager = struct {
    io: Io,
    file: Io.File,
    page_count: u64,

    pub const Error = error{ ShortRead, CorruptFile } ||
        Io.File.OpenError || Io.File.StatError ||
        Io.File.ReadPositionalError || Io.File.WritePositionalError ||
        Io.File.SyncError;

    /// Create or open `sub_path` inside `dir` for read+write without truncating.
    pub fn open(io: Io, dir: Io.Dir, sub_path: []const u8) Error!Pager {
        const file = try dir.createFile(io, sub_path, .{
            .read = true, // default is write-only!
            .truncate = false, // default is true!
        });
        errdefer file.close(io);
        const size = try file.length(io); // or (try file.stat(io)).size
        if (size % page_size != 0) return error.CorruptFile;
        return .{ .io = io, .file = file, .page_count = size / page_size };
    }

    pub fn close(self: *Pager) void {
        self.file.close(self.io);
        self.* = undefined;
    }

    /// pread: fills the whole buffer or reports a short read.
    pub fn readPage(self: *Pager, page_no: u64, out: *Page) Error!void {
        const n = try self.file.readPositionalAll(self.io, out, page_no * page_size);
        if (n != page_size) return error.ShortRead;
    }

    /// pwrite: writes all bytes at the offset; extends the file if needed.
    pub fn writePage(self: *Pager, page_no: u64, page: *const Page) Error!void {
        try self.file.writePositionalAll(self.io, page, page_no * page_size);
        self.page_count = @max(self.page_count, page_no + 1);
    }

    pub fn allocPage(self: *Pager) Error!u64 {
        const page_no = self.page_count;
        const zero: Page = @splat(0);
        try self.writePage(page_no, &zero);
        return page_no;
    }

    /// fsync
    pub fn sync(self: *Pager) Error!void {
        try self.file.sync(self.io);
    }
};

test "pager round trip in a temp dir" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{}); // .zig-cache/tmp/<random>/ ; tmp.dir is an Io.Dir
    defer tmp.cleanup();

    {
        var pager: Pager = try .open(io, tmp.dir, "test.db");
        defer pager.close();
        try testing.expectEqual(0, pager.page_count);

        var page: Page = @splat(0);
        std.mem.writeInt(u32, page[0..4], 0xB7EE, .little);
        @memcpy(page[8..13], "hello");
        try pager.writePage(3, &page); // sparse write: pages 0..2 read back as zeroes
        try pager.sync();
        try testing.expectEqual(4, pager.page_count);
        try testing.expectEqual(4, try pager.allocPage());
    }

    // Reopen and read back.
    var pager: Pager = try .open(io, tmp.dir, "test.db");
    defer pager.close();
    try testing.expectEqual(5, pager.page_count);

    var page: Page = undefined;
    try pager.readPage(3, &page);
    try testing.expectEqual(0xB7EE, std.mem.readInt(u32, page[0..4], .little));
    try testing.expectEqualStrings("hello", page[8..13]);
    try pager.readPage(0, &page);
    try testing.expect(std.mem.allEqual(u8, &page, 0));
    try testing.expectError(error.ShortRead, pager.readPage(99, &page));
}

test "raw file API tour" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir: Io.Dir = tmp.dir; // Io.Dir.cwd() for the working directory

    // --- create (truncates, write-only by default) ---
    const f = try dir.createFile(io, "a.bin", .{ .read = true });
    // .exclusive = true -> error.PathAlreadyExists if it exists
    // .lock = .exclusive -> advisory file lock (single-writer database)

    // --- positional write (pwrite) ---
    try f.writePositionalAll(io, "0123456789", 0);
    try f.writePositionalAll(io, "AB", 4);
    // vectored: returns bytes written, may be short
    _ = try f.writePositional(io, &.{ "x", "y" }, 8);

    // --- positional read (pread) ---
    var buf: [10]u8 = undefined;
    const n = try f.readPositionalAll(io, &buf, 0); // n < buf.len means EOF
    try testing.expectEqualStrings("0123AB67xy", buf[0..n]);
    var small: [4]u8 = undefined;
    const m = try f.readPositional(io, &.{&small}, 8); // vectored, may be short
    try testing.expectEqual(2, m);

    // --- size / truncate / extend ---
    try testing.expectEqual(10, try f.length(io));
    try f.setLength(io, 4096); // ftruncate: grow (zero-filled) or shrink
    const st = try f.stat(io);
    try testing.expectEqual(4096, st.size);
    try testing.expectEqual(Io.File.Kind.file, st.kind);

    // --- durability ---
    try f.sync(io);
    f.close(io); // close cannot fail and takes io

    // --- reopen existing file ---
    const g = try dir.openFile(io, "a.bin", .{ .mode = .read_write }); // .read_only (default), .write_only
    defer g.close(io);
    try testing.expectError(error.FileNotFound, dir.openFile(io, "missing.bin", .{}));

    // --- rename (atomic replace), exists check, delete ---
    try dir.rename("a.bin", dir, "b.bin", io);
    try dir.access(io, "b.bin", .{});
    try testing.expectError(error.FileNotFound, dir.access(io, "a.bin", .{}));
    try dir.deleteFile(io, "b.bin");

    // --- directories ---
    try dir.createDirPath(io, "x/y/z");
    try dir.deleteTree(io, "x");
}

test "whole-file helpers and buffered sequential I/O (WAL-style append)" {
    const io = testing.io;
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "small.txt", .data = "hello\nworld\n" });
    const contents = try tmp.dir.readFileAlloc(io, "small.txt", gpa, .limited(1 << 20));
    defer gpa.free(contents);
    try testing.expectEqualStrings("hello\nworld\n", contents);

    // Buffered sequential writer: File.Writer owns position + buffer; `.interface` is the *Io.Writer.
    const f = try tmp.dir.createFile(io, "wal.log", .{ .read = true });
    defer f.close(io);
    var wbuf: [256]u8 = undefined;
    var fw: Io.File.Writer = f.writer(io, &wbuf);
    const w: *Io.Writer = &fw.interface;
    try w.writeInt(u32, 0xCAFE, .little);
    try w.print("record {d}\n", .{1});
    try w.flush(); // required before sync / reading back
    try f.sync(io);

    // Buffered sequential reader: `.interface` is the *Io.Reader.
    var rbuf: [256]u8 = undefined;
    var fr: Io.File.Reader = f.reader(io, &rbuf);
    const r: *Io.Reader = &fr.interface;
    try testing.expectEqual(0xCAFE, try r.takeInt(u32, .little));
    const line = (try r.takeDelimiter('\n')).?; // null at EOF
    try testing.expectEqualStrings("record 1", line);
    try testing.expectError(error.EndOfStream, r.takeByte());
}
