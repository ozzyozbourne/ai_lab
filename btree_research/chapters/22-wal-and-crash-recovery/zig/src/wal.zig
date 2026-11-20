//! wal.zig: a write-ahead log with full page images (physical redo).
//!
//! The `Wal` sits between the pager and two files, and looks like a storage
//! to the pager (chapter 12's interface, see adapter.zig):
//!
//!   DiskBTree -> BufferPool -> Pager -> Wal -+-> log file   (appended, synced at commit)
//!                                            +-> main file  (written only by checkpoint)
//!
//!   write(page)   keep the image in `pending` (memory). Nothing reaches a file.
//!   sync()        COMMIT: append one record per pending page and a commit
//!                 record to the log, sync the log. The images move to `index`.
//!   read(page)    newest image wins: pending, then index, then the main file
//!                 (whose page checksum is verified).
//!   checkpoint()  write every image of `index` to the main file, sync it,
//!                 then start a new, empty generation of the log.
//!   recover()     on open: scan the log, replay committed operations into
//!                 the main file, start a new generation.
//!
//! The write-ahead rule: a page reaches the main file only after the log
//! record holding its image is durable. It holds by construction: `checkpoint`
//! and `recover` are the only code that writes the main file, and both write
//! only images that were read back from, or already synced to, the log.
//!
//! The buffer pool may evict a dirty page in the middle of an operation. Its
//! write-back arrives here as `write` and lands in `pending`, so eviction is
//! routed through the log and can never put an uncommitted page into the main
//! file. The pool needs no change and can stay as small as 2 frames.
//!
//! Log file layout (all integers little-endian)
//! ============================================
//!
//!   log page 0          header, alone on its page
//!      0  [8]  magic "WAL22\0\0\0"
//!      8  u32  format version (1)
//!     12  u32  page size (4096)
//!     16  u64  generation: +1 at every reset; the old records stay in the
//!              file but no longer chain from the header
//!     24  u64  LSN of the first record of this generation
//!     32  u32  CRC-32 of bytes 0..32
//!   byte 4096 onwards   records, back to back, crossing page boundaries
//!      0  u64  LSN (log sequence number): 1, 2, 3, ... never reused
//!      8  u32  kind: 1 = page image, 2 = commit
//!     12  u32  page image: the page id; commit: number of page records
//!     16  u32  payload length: 4096 for a page image, 0 for a commit
//!     20  u32  CRC-32 of (previous record's CRC ++ bytes 0..20 ++ payload)
//!     24  ...  payload
//!
//! The checksum chain. Each CRC covers the CRC before it; the first one
//! covers the header's CRC. A record is valid only if every record before it
//! is valid. So the scan stops at the first torn record, and also at a record
//! left over from an earlier generation: it has a good CRC of its own, but
//! not one that chains from today's header.
//!
//! Why the header page is safe to overwrite in place: all of it lies in the
//! first 512-byte sector, which the disk writes atomically (chapter 21).
//! Why rewriting the last, partly filled log page is safe: the bytes of the
//! earlier records on it are rewritten with identical contents, so a sector
//! that is torn there is the same before and after.
//!
//! Memory (see README "Allocator notes")
//!   record_buffer  one slab, allocated once; a FixedBufferAllocator assembles
//!                  the records of one commit in it and is reset per commit
//!   pending/index  page images from the general-purpose allocator
//!   recovery       an arena that lives exactly as long as `recover`
const std = @import("std");
const Allocator = std.mem.Allocator;
const crc = @import("crc32.zig");
const checksum = @import("base_checksum.zig");
const byte_storage = @import("base_storage.zig");
const ByteStorage = byte_storage.Storage;
const page_storage = @import("base_page_storage.zig");
const PageStorage = page_storage.Storage;
const adapter = @import("adapter.zig");

pub const Page = page_storage.Page;
pub const page_size = page_storage.page_size;
pub const PageId = u32;

pub const log_magic = "WAL22\x00\x00\x00";
pub const log_version: u32 = 1;
/// Byte offset of the first record: the header has log page 0 to itself.
pub const log_start: u64 = page_size;
pub const record_header_len = 24;
pub const kind_page: u32 = 1;
pub const kind_commit: u32 = 2;

/// Sorted map from page id to an owned page image. Small (the pages of one
/// commit, or of the commits since the last checkpoint), so a sorted array
/// with binary search is enough, and iterating it visits pages in page-id
/// order: the order every write in this file uses.
pub const PageTable = struct {
    entries: std.ArrayList(Entry) = .empty,

    pub const Entry = struct { id: PageId, image: *Page };

    fn lowerBound(self: *const PageTable, id: PageId) usize {
        var lo: usize = 0;
        var hi: usize = self.entries.items.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.entries.items[mid].id < id) lo = mid + 1 else hi = mid;
        }
        return lo;
    }

    pub fn find(self: *const PageTable, id: PageId) ?*Page {
        const i = self.lowerBound(id);
        if (i < self.entries.items.len and self.entries.items[i].id == id) return self.entries.items[i].image;
        return null;
    }

    /// Store a copy of `bytes` as the image of page `id`, replacing an older one.
    pub fn put(self: *PageTable, allocator: Allocator, id: PageId, bytes: *const Page) Allocator.Error!void {
        const i = self.lowerBound(id);
        if (i < self.entries.items.len and self.entries.items[i].id == id) {
            self.entries.items[i].image.* = bytes.*;
            return;
        }
        try self.entries.ensureUnusedCapacity(allocator, 1);
        const image = try allocator.create(Page);
        image.* = bytes.*;
        self.entries.insertAssumeCapacity(i, .{ .id = id, .image = image });
    }

    /// Number of pages needed to hold the highest page id (0 if empty).
    pub fn pageCount(self: *const PageTable) u64 {
        const items = self.entries.items;
        return if (items.len == 0) 0 else @as(u64, items[items.len - 1].id) + 1;
    }

    pub fn len(self: *const PageTable) usize {
        return self.entries.items.len;
    }

    /// Free every image, keep the list's capacity.
    pub fn clear(self: *PageTable, allocator: Allocator) void {
        for (self.entries.items) |e| allocator.destroy(e.image);
        self.entries.clearRetainingCapacity();
    }

    pub fn deinit(self: *PageTable, allocator: Allocator) void {
        self.clear(allocator);
        self.entries.deinit(allocator);
    }
};

/// What `recover` found in the log.
pub const Recovery = struct {
    /// Generation of the log that was scanned (0 = there was no log).
    generation: u64 = 0,
    /// Records whose checksum chain was intact.
    valid_records: u32 = 0,
    /// Operations with a commit record: these were replayed.
    committed_ops: u32 = 0,
    /// Distinct pages written to the main file by the replay.
    pages_replayed: u32 = 0,
    /// Valid page records after the last commit record: an operation that
    /// was still being logged when the power failed. Ignored.
    uncommitted_records: u32 = 0,
};

pub const Stats = struct {
    commits: u64 = 0,
    page_records: u64 = 0,
    /// Bytes of records appended to the log, over all generations.
    log_bytes: u64 = 0,
    /// The longest the record area of the log ever was, in bytes.
    max_log_bytes: u64 = 0,
    /// The most page images one commit carried.
    largest_commit: u64 = 0,
    log_page_writes: u64 = 0,
    log_syncs: u64 = 0,
    checkpoints: u64 = 0,
    main_page_writes: u64 = 0,
    main_syncs: u64 = 0,
    /// Pages read from the main file whose checksum did not verify.
    checksum_failures: u64 = 0,
};

pub const Options = struct {
    /// Upper bound on the pages one commit may log; sizes `record_buffer`.
    max_commit_pages: u32 = 32,
};

pub const Wal = struct {
    gpa: Allocator,
    main: PageStorage,
    log: PageStorage,
    /// Images the pager wrote since the last commit. Volatile, uncommitted.
    pending: PageTable = .{},
    /// Committed images that are in the log but not yet in the main file.
    /// (SQLite and Turso keep frame numbers here and re-read the log; this
    /// chapter keeps the images themselves.)
    index: PageTable = .{},
    generation: u64 = 0,
    next_lsn: u64 = 1,
    /// CRC of the last valid record (or of the header): the chain's end.
    chain: u32 = 0,
    /// Byte offset in the log file where the next record goes.
    tail: u64 = log_start,
    /// The contents of the log page that contains `tail`.
    tail_page: Page = @splat(0),
    record_buffer: []u8,
    commits_in_log: u32 = 0,
    /// Set while the files and this struct may disagree: before `recover`,
    /// and after a commit or checkpoint failed half-way. Only a new `Wal`
    /// that runs `recover` can be trusted then.
    broken: bool = true,
    /// The most recent error that the storage interface had to flatten.
    last_error: ?Error = null,
    stats: Stats = .{},

    pub const Error = PageStorage.Error || error{
        /// The log header is damaged in a way a power cut cannot explain.
        LogCorrupt,
        /// One commit dirtied more pages than `max_commit_pages`.
        CommitTooLarge,
        /// An earlier commit or checkpoint failed; reopen to recover.
        WalBroken,
    };

    /// Allocate the record buffer. The log is not read: call `recover` next.
    pub fn init(gpa: Allocator, main: PageStorage, log: PageStorage, options: Options) Allocator.Error!Wal {
        const bytes = @as(usize, options.max_commit_pages) * (record_header_len + page_size) + record_header_len;
        return .{ .gpa = gpa, .main = main, .log = log, .record_buffer = try gpa.alloc(u8, bytes) };
    }

    pub fn deinit(self: *Wal) void {
        self.pending.deinit(self.gpa);
        self.index.deinit(self.gpa);
        self.gpa.free(self.record_buffer);
        self.* = undefined;
    }

    // ---- commit ---------------------------------------------------------------

    /// Make every pending page image durable as ONE operation: page records,
    /// then a commit record, then one sync of the log. When this returns the
    /// operation survives any crash; if the power fails before the sync
    /// completes, recovery sees no commit record and ignores all of it.
    pub fn commit(self: *Wal) Error!void {
        if (self.broken) return error.WalBroken;
        if (self.pending.len() == 0) return; // nothing changed: nothing to log

        // Everything that can fail for lack of memory happens first, while
        // giving up is still harmless.
        try self.index.entries.ensureUnusedCapacity(self.gpa, self.pending.len());

        // Assemble the records back to back in the fixed buffer. A bump
        // allocator hands out adjacent slices, so the buffer's used prefix
        // IS the byte run to append; running out of it is the size limit.
        var fba: std.heap.FixedBufferAllocator = .init(self.record_buffer);
        const a = fba.allocator();
        var chain = self.chain;
        var lsn = self.next_lsn;
        for (self.pending.entries.items) |e| {
            // Seal first: the image in the log carries the page checksum, so
            // checkpoint and recovery can copy it to the main file verbatim.
            checksum.seal(e.image, e.id);
            const rec = a.alloc(u8, record_header_len + page_size) catch return error.CommitTooLarge;
            @memcpy(rec[record_header_len..], e.image);
            chain = encodeRecord(rec, lsn, kind_page, e.id, chain);
            lsn += 1;
        }
        const commit_rec = a.alloc(u8, record_header_len) catch return error.CommitTooLarge;
        chain = encodeRecord(commit_rec, lsn, kind_commit, @intCast(self.pending.len()), chain);
        lsn += 1;
        const run = self.record_buffer[0..fba.end_index];

        // From here on a failure leaves the log in a state only recovery
        // can interpret.
        self.broken = true;
        try self.appendToLog(run);
        try self.log.sync();
        self.stats.log_syncs += 1;
        // ---- the commit point: the operation is durable ----

        for (self.pending.entries.items) |e| {
            if (self.index.find(e.id)) |older| {
                older.* = e.image.*;
                self.gpa.destroy(e.image);
            } else {
                // Ownership of the image moves; capacity was reserved above.
                self.index.entries.insertAssumeCapacity(self.index.lowerBound(e.id), e);
            }
        }
        self.stats.page_records += self.pending.len();
        self.stats.largest_commit = @max(self.stats.largest_commit, self.pending.len());
        self.pending.entries.clearRetainingCapacity();
        self.chain = chain;
        self.next_lsn = lsn;
        self.commits_in_log += 1;
        self.stats.commits += 1;
        self.stats.log_bytes += run.len;
        self.stats.max_log_bytes = @max(self.stats.max_log_bytes, self.tail - log_start);
        self.broken = false;
    }

    /// Write `run` at `tail`. The log file is page-addressed, so the first
    /// write usually rewrites the partly filled last page (see the top).
    fn appendToLog(self: *Wal, run: []const u8) Error!void {
        var rest = run;
        while (rest.len > 0) {
            const offset: usize = @intCast(self.tail % page_size);
            if (offset == 0) @memset(&self.tail_page, 0);
            const n = @min(rest.len, page_size - offset);
            @memcpy(self.tail_page[offset..][0..n], rest[0..n]);
            try self.log.writePage(self.tail / page_size, &self.tail_page);
            self.stats.log_page_writes += 1;
            self.tail += n;
            rest = rest[n..];
        }
    }

    // ---- checkpoint -----------------------------------------------------------

    /// Copy every committed image to the main file, sync it, then empty the
    /// log. A crash anywhere in here is harmless: until the new log header
    /// is durable the old log is still complete, and recovery replays it
    /// over whatever the interrupted checkpoint left (redo is idempotent:
    /// writing the same image twice gives the same page).
    pub fn checkpoint(self: *Wal) Error!void {
        if (self.broken) return error.WalBroken;
        self.broken = true;
        try self.writeToMain(&self.index);
        try self.resetLog();
        self.index.clear(self.gpa);
        self.stats.checkpoints += 1;
        self.broken = false;
    }

    fn writeToMain(self: *Wal, table: *const PageTable) Error!void {
        if (table.len() == 0) return;
        for (table.entries.items) |e| {
            try self.main.writePage(e.id, e.image);
            self.stats.main_page_writes += 1;
        }
        try self.main.sync();
        self.stats.main_syncs += 1;
    }

    /// Start a new generation: one header write, one sync. The old records
    /// are not erased; they stop being reachable because their checksums
    /// chain from the old header.
    fn resetLog(self: *Wal) Error!void {
        var header: Page = @splat(0);
        const header_crc = encodeHeader(&header, self.generation + 1, self.next_lsn);
        try self.log.writePage(0, &header);
        self.stats.log_page_writes += 1;
        try self.log.sync();
        self.stats.log_syncs += 1;
        self.generation += 1;
        self.chain = header_crc;
        self.tail = log_start;
        self.commits_in_log = 0;
    }

    // ---- recovery -------------------------------------------------------------

    /// Bring the main file to the state after the last committed operation.
    ///
    ///   1. scan the log from the start; stop at the first record whose
    ///      checksum chain breaks (torn, never written, or an old generation)
    ///   2. page records are collected per operation; a commit record
    ///      promotes them, a missing one means they are dropped
    ///   3. write the newest committed image of each page to the main file,
    ///      sync, start a new log generation (a checkpoint)
    ///
    /// Running it twice, or crashing inside it and running it again, gives
    /// the same main file: step 3 only copies images.
    pub fn recover(self: *Wal) Error!Recovery {
        // Every image read from the log lives in this arena and dies with it
        // when recovery is over: one free for the lot.
        var arena_state: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        var scanner: LogScanner = try .init(self.log);
        var report: Recovery = .{ .generation = scanner.generation };
        var committed: PageTable = .{};
        var open_op: std.ArrayList(PageTable.Entry) = .empty; // records since the last commit
        var spare: ?*Page = null;
        while (true) {
            const image = spare orelse try arena.create(Page);
            spare = image;
            const rec = try scanner.next(image) orelse break;
            report.valid_records += 1;
            if (rec.kind == kind_page) {
                try open_op.append(arena, .{ .id = rec.arg, .image = image });
                spare = null; // the image is in use; the next record gets a new one
                continue;
            }
            // A commit record says how many page records it closes; with an
            // intact chain the count cannot be wrong unless the writer was.
            if (rec.arg != open_op.items.len) return error.LogCorrupt;
            // The newest image of a page wins; an older one
            // is simply forgotten: the arena frees it with everything else.
            for (open_op.items) |e| {
                const i = committed.lowerBound(e.id);
                const items = committed.entries.items;
                if (i < items.len and items[i].id == e.id) items[i].image = e.image else try committed.entries.insert(arena, i, e);
            }
            open_op.clearRetainingCapacity();
            report.committed_ops += 1;
        }
        report.uncommitted_records = @intCast(open_op.items.len);
        report.pages_replayed = @intCast(committed.len());

        // Redo, then checkpoint. `next_lsn` moves past every record that was
        // valid, committed or not, so no LSN is ever handed out twice.
        self.generation = scanner.generation;
        self.next_lsn = scanner.lsn;
        try self.writeToMain(&committed);
        try self.resetLog();
        self.broken = false;
        return report;
    }

    // ---- the storage interface the pager sees ------------------------------------

    /// Pages in the database as the tree sees it: the main file, extended
    /// by any newer page that so far exists only in the log or in memory.
    pub fn pageCount(self: *const Wal) u64 {
        return @max(self.main.size(), @max(self.index.pageCount(), self.pending.pageCount()));
    }

    /// The interface value. `self` must outlive it and must not move.
    pub fn storage(self: *Wal) ByteStorage {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: ByteStorage.VTable = .{ .read = vtRead, .write = vtWrite, .size = vtSize, .sync = vtSync };

    fn fail(self: *Wal, err: Error) ByteStorage.Error {
        self.last_error = err;
        return error.StorageFailure;
    }

    fn vtRead(ptr: *anyopaque, offset: u64, buffer: []u8) ByteStorage.Error!void {
        const self: *Wal = @ptrCast(@alignCast(ptr));
        if (self.broken) return self.fail(error.WalBroken);
        const page_no = adapter.wholePage(offset, buffer.len) orelse return error.StorageFailure;
        if (page_no >= self.pageCount()) return error.ShortRead;
        const out = buffer[0..page_size];
        const id: PageId = @intCast(page_no);
        if (self.pending.find(id) orelse self.index.find(id)) |image| {
            out.* = image.*;
        } else switch (checksum.readChecked(self.main, page_no, out) catch |err| return self.fail(err)) {
            .ok => {},
            // Every page of the main file was written by a checkpoint, sealed.
            // Anything else is damage the log can no longer repair.
            .blank, .corrupt => {
                self.stats.checksum_failures += 1;
                return error.StorageFailure;
            },
        }
        // The tree was promised a zero tail (chapter 12); the checksum that
        // lives there on disk is this layer's business only.
        @memset(out[checksum.payload_size..], 0);
    }

    fn vtWrite(ptr: *anyopaque, offset: u64, bytes: []const u8) ByteStorage.Error!void {
        const self: *Wal = @ptrCast(@alignCast(ptr));
        if (self.broken) return self.fail(error.WalBroken);
        const page_no = adapter.wholePage(offset, bytes.len) orelse return error.StorageFailure;
        if (page_no >= std.math.maxInt(PageId)) return error.StorageFailure;
        self.pending.put(self.gpa, @intCast(page_no), bytes[0..page_size]) catch return self.fail(error.OutOfMemory);
    }

    fn vtSize(ptr: *anyopaque) ByteStorage.Error!u64 {
        const self: *Wal = @ptrCast(@alignCast(ptr));
        return self.pageCount() * page_size;
    }

    fn vtSync(ptr: *anyopaque) ByteStorage.Error!void {
        const self: *Wal = @ptrCast(@alignCast(ptr));
        self.commit() catch |err| return self.fail(err);
    }
};

// ---- reading the log -----------------------------------------------------------

/// Walks the valid prefix of the log: `next` returns one record after the
/// other and null as soon as the checksum chain ends. Used by recovery, and
/// by anything that wants to look at a log (the demo prints one).
pub const LogScanner = struct {
    log: PageStorage,
    /// 0 = the file has no header: there is no log.
    generation: u64 = 0,
    /// The LSN the next record must carry.
    lsn: u64 = 1,
    /// The CRC the next record must chain from.
    chain: u32 = 0,
    /// Byte offset of the next record.
    pos: u64 = log_start,
    cached: ?u64 = null,
    page: Page = undefined,

    pub const Record = struct { lsn: u64, kind: u32, arg: u32, crc: u32, offset: u64 };

    pub fn init(log: PageStorage) Wal.Error!LogScanner {
        var self: LogScanner = .{ .log = log };
        var header: Page = undefined;
        if (try self.read(0, &header)) {
            if (decodeHeader(&header)) |h| {
                self.generation = h.generation;
                self.lsn = h.first_lsn;
                self.chain = h.crc;
            } else if (!std.mem.allEqual(u8, &header, 0)) return error.LogCorrupt;
        }
        return self;
    }

    /// The next valid record, or null at the end of the chain. For a page
    /// record its image is copied to `image`.
    pub fn next(self: *LogScanner, image: *Page) Wal.Error!?Record {
        if (self.generation == 0) return null;
        var head: [record_header_len]u8 = undefined;
        if (!try self.read(self.pos, &head)) return null; // end of the file
        const kind = std.mem.readInt(u32, head[8..12], .little);
        const payload_len = std.mem.readInt(u32, head[16..20], .little);
        // Cheap plausibility checks before trusting the length field. A
        // record with the wrong LSN is stale even if its bytes are intact.
        if (std.mem.readInt(u64, head[0..8], .little) != self.lsn) return null;
        const is_page = kind == kind_page and payload_len == page_size;
        if (!is_page and !(kind == kind_commit and payload_len == 0)) return null;
        if (is_page and !try self.read(self.pos + record_header_len, image)) return null;
        const payload: []const u8 = if (is_page) image else &.{};
        const sum = recordCrc(self.chain, head[0..20], payload);
        if (sum != std.mem.readInt(u32, head[20..24], .little)) return null; // the chain breaks here
        const rec: Record = .{ .lsn = self.lsn, .kind = kind, .arg = std.mem.readInt(u32, head[12..16], .little), .crc = sum, .offset = self.pos };
        self.chain = sum;
        self.lsn += 1;
        self.pos += record_header_len + payload_len;
        return rec;
    }

    /// Copy a byte range of the page-addressed log file, through a one-page
    /// cache. false = the range reaches past the end of the file.
    fn read(self: *LogScanner, pos: u64, out: []u8) PageStorage.Error!bool {
        var done: usize = 0;
        while (done < out.len) {
            const at = pos + done;
            const page_no = at / page_size;
            if (self.cached != page_no) {
                self.cached = null;
                self.log.readPage(page_no, &self.page) catch |err| switch (err) {
                    error.OutOfBounds => return false,
                    else => return err,
                };
                self.cached = page_no;
            }
            const offset: usize = @intCast(at % page_size);
            const n = @min(out.len - done, page_size - offset);
            @memcpy(out[done..][0..n], self.page[offset..][0..n]);
            done += n;
        }
        return true;
    }
};

// ---- encoding ------------------------------------------------------------------

/// Fill in a record's 24-byte header (the payload must already be in place
/// behind it) and return its CRC, the next link of the chain.
pub fn encodeRecord(rec: []u8, lsn: u64, kind: u32, arg: u32, prev_crc: u32) u32 {
    std.mem.writeInt(u64, rec[0..8], lsn, .little);
    std.mem.writeInt(u32, rec[8..12], kind, .little);
    std.mem.writeInt(u32, rec[12..16], arg, .little);
    std.mem.writeInt(u32, rec[16..20], @intCast(rec.len - record_header_len), .little);
    const sum = recordCrc(prev_crc, rec[0..20], rec[record_header_len..]);
    std.mem.writeInt(u32, rec[20..24], sum, .little);
    return sum;
}

/// One link of the checksum chain: CRC-32 over the previous record's CRC
/// (4 bytes, little-endian), the first 20 header bytes, and the payload.
pub fn recordCrc(prev_crc: u32, head: *const [20]u8, payload: []const u8) u32 {
    var prev: [4]u8 = undefined;
    std.mem.writeInt(u32, &prev, prev_crc, .little);
    return crc.crc32Update(crc.crc32Update(crc.crc32(&prev), head), payload);
}

pub fn encodeHeader(page: *Page, generation: u64, first_lsn: u64) u32 {
    @memset(page, 0);
    @memcpy(page[0..8], log_magic);
    std.mem.writeInt(u32, page[8..12], log_version, .little);
    std.mem.writeInt(u32, page[12..16], page_size, .little);
    std.mem.writeInt(u64, page[16..24], generation, .little);
    std.mem.writeInt(u64, page[24..32], first_lsn, .little);
    const sum = crc.crc32(page[0..32]);
    std.mem.writeInt(u32, page[32..36], sum, .little);
    return sum;
}

pub const Header = struct { generation: u64, first_lsn: u64, crc: u32 };

pub fn decodeHeader(page: *const Page) ?Header {
    if (!std.mem.eql(u8, page[0..8], log_magic)) return null;
    if (std.mem.readInt(u32, page[8..12], .little) != log_version) return null;
    if (std.mem.readInt(u32, page[12..16], .little) != page_size) return null;
    const sum = crc.crc32(page[0..32]);
    if (std.mem.readInt(u32, page[32..36], .little) != sum) return null;
    return .{
        .generation = std.mem.readInt(u64, page[16..24], .little),
        .first_lsn = std.mem.readInt(u64, page[24..32], .little),
        .crc = sum,
    };
}
