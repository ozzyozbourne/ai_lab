//! db.zig: the disk tree of chapter 12 behind the write-ahead log.
//!
//!   Db.open     recover (replay the log), then open the tree, or create it
//!               if the files are empty
//!   Db.put      tree.put, then tree.flush. `flush` writes the dirty pages
//!               and the metapage to the storage and syncs it; the storage is
//!               the `Wal`, whose sync is a commit. When `put` returns, the
//!               key is durable. A checkpoint follows every few commits.
//!   Db.putBatch several puts, ONE commit: all of them or none of them.
//!
//! Nothing in the tree, the buffer pool or the pager changed for this: the
//! log was slid in underneath, at the one interface they all share.
//!
//! An error from `put` means "outcome unknown", not "not stored": the power
//! may have failed after the commit record became durable but before `put`
//! could return. After such an error the handle must be closed and the
//! database reopened; recovery then decides. The handle enforces this: once
//! `put`, `putBatch` or `checkpoint` has failed after it started to change
//! something, every later call returns `error.ReopenRequired`. Without that,
//! the pages a failed operation left in memory would be committed by the
//! next successful one. The one error that leaves the handle usable is a key
//! or value that is too long: it is found before anything is touched.
const std = @import("std");
const Allocator = std.mem.Allocator;
const page_storage = @import("base_page_storage.zig");
const PageStorage = page_storage.Storage;
const Pager = @import("base_pager.zig").Pager;
const BufferPool = @import("base_buffer_pool.zig").BufferPool;
const btree = @import("base_disk_btree.zig");
const DiskBTree = btree.DiskBTree;
const wal_mod = @import("wal.zig");
const Wal = wal_mod.Wal;

pub const Options = struct {
    /// Buffer pool size, at least 1 (the pool asserts it). 2 is enough:
    /// evicted dirty pages go to the log layer.
    frames: u32 = 8,
    /// Checkpoint when this many commits are in the log. 0 = never.
    checkpoint_every: u32 = 4,
    max_commit_pages: u32 = 32,
};

pub const KeyValue = struct { key: []const u8, value: []const u8 };

pub const Db = struct {
    gpa: Allocator,
    options: Options,
    wal: Wal,
    pager: Pager,
    pool: BufferPool,
    tree: DiskBTree,
    /// What recovery found when this handle was opened.
    recovery: wal_mod.Recovery,
    /// Set when an operation failed half-way: the buffer pool and the log
    /// layer may hold pages of an operation that never committed.
    failed: bool,

    pub const Error = DiskBTree.Error || Wal.Error || error{
        /// An earlier operation on this handle failed. Close it and open
        /// the database again; recovery decides what was stored.
        ReopenRequired,
    };

    /// The struct holds pointers into itself (pager -> wal, pool -> pager,
    /// tree -> pool), so it lives on the heap and never moves.
    pub fn open(gpa: Allocator, main: PageStorage, log: PageStorage, options: Options) Error!*Db {
        const self = try gpa.create(Db);
        errdefer gpa.destroy(self);
        self.gpa = gpa;
        self.options = options;
        self.failed = false;
        self.wal = try .init(gpa, main, log, .{ .max_commit_pages = options.max_commit_pages });
        errdefer self.wal.deinit();
        self.recovery = try self.wal.recover();
        self.pager = try .init(self.wal.storage());
        self.pool = try .init(gpa, &self.pager, options.frames);
        errdefer self.pool.deinit();
        // No pages at all: a new database, or one whose creation never
        // committed. Creating it is itself a logged, committed operation.
        self.tree = if (self.pager.pageCount() == 0) try .create(gpa, &self.pool) else try .open(gpa, &self.pool);
        return self;
    }

    /// Free the memory. There is nothing to flush: every `put` that returned
    /// is already in the log.
    pub fn close(self: *Db) void {
        const gpa = self.gpa;
        self.tree.deinit();
        self.pool.deinit();
        self.wal.deinit();
        gpa.destroy(self);
    }

    /// Insert or overwrite one key. Atomic and durable at return.
    pub fn put(self: *Db, key: []const u8, value: []const u8) Error!void {
        return self.putBatch(&.{.{ .key = key, .value = value }});
    }

    /// Insert or overwrite several keys as one operation with one commit
    /// record: after a crash either all of them are there or none.
    pub fn putBatch(self: *Db, pairs: []const KeyValue) Error!void {
        if (self.failed) return error.ReopenRequired;
        // Refuse a pair the tree would refuse BEFORE the first one is
        // applied: the tree has no undo, so a batch that stops in the middle
        // cannot be taken back.
        for (pairs) |kv| {
            if (kv.key.len > btree.max_key_len) return error.KeyTooLarge;
            if (kv.value.len > btree.max_value_len) return error.ValueTooLarge;
        }
        // From here on an error leaves uncommitted pages behind.
        errdefer self.failed = true;
        for (pairs) |kv| try self.tree.put(kv.key, kv.value);
        try self.commit();
    }

    fn commit(self: *Db) Error!void {
        // flush = write the metapage and every dirty page, then sync. The
        // writes land in the Wal's pending table; the sync is `Wal.commit`.
        try self.tree.flush();
        if (self.options.checkpoint_every != 0 and self.wal.commits_in_log >= self.options.checkpoint_every) {
            try self.wal.checkpoint();
        }
    }

    pub fn checkpoint(self: *Db) Error!void {
        if (self.failed) return error.ReopenRequired;
        errdefer self.failed = true;
        try self.wal.checkpoint();
    }

    /// Caller frees the returned value with `allocator`.
    pub fn get(self: *Db, allocator: Allocator, key: []const u8) Error!?[]u8 {
        if (self.failed) return error.ReopenRequired; // it would show uncommitted pages
        return self.tree.get(allocator, key);
    }

    pub fn range(self: *Db, lo: []const u8, hi: ?[]const u8) Error!DiskBTree.RangeIterator {
        if (self.failed) return error.ReopenRequired;
        return self.tree.range(lo, hi);
    }

    pub fn validate(self: *Db) (Error || DiskBTree.ValidateError)!void {
        if (self.failed) return error.ReopenRequired;
        return self.tree.validate();
    }
};
