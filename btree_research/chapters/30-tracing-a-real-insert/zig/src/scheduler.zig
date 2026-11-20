//! scheduler.zig: the two things a resumable operation needs around it.
//!
//!   SimDisk    a "disk" whose reads complete LATER, in a seeded pseudo-random
//!              order. Submitting a read returns at once; `completeOne` picks
//!              one pending request and only then moves the bytes into the
//!              buffer pool. This is the only place in the chapter where a
//!              page is read.
//!   Scheduler  a cooperative scheduler on one thread: it steps operations
//!              until they yield, hands their requests to the disk, and wakes
//!              each one when its page has arrived.
//!
//! Who may run together. Reads of DIFFERENT lookups interleave freely: the
//! scheduler admits any number of `get`s at once and their page requests
//! complete in whatever order the disk likes. A writer runs ALONE: an insert
//! is admitted only when nothing else is in flight, and nothing else is
//! admitted until it is done. The reason is visible in this very tree: an
//! insert that yields between `splitLeaf` and `insertSeparator` has left a
//! leaf whose right half no parent points to yet. A reader let in at that
//! moment would descend into the left half and miss keys that exist
//! (tests.zig shows it happen). PostgreSQL solves this inside the tree, with
//! right links and high keys (chapter 20), and lets writers overlap. Turso
//! keeps the tree simple and solves it outside: one write transaction at a
//! time (turso/core/storage/wal.rs:3587-3589), while readers look at the snapshot
//! in the WAL instead of the writer's dirty pages (chapter 22). This file
//! does the cruder thing and makes readers wait for the writer.
//!
//! Operations are admitted in the order they were submitted, so the result
//! is the one a blocking program would get by running them one by one.
const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const btree = @import("disk_btree.zig");
const DiskBTree = btree.DiskBTree;
const PageId = btree.PageId;
const BufferPool = @import("base_buffer_pool.zig").BufferPool;
const SplitMix64 = @import("prng.zig").SplitMix64;
const resumable = @import("resumable.zig");
const InsertOp = resumable.InsertOp;
const GetOp = resumable.GetOp;

pub const SimDisk = struct {
    pool: *BufferPool,
    rng: SplitMix64,
    pending: std.ArrayList(Request) = .empty,
    /// Requests completed, and how many of them really read the storage
    /// (the others found the page already brought in for somebody else).
    completions: u64 = 0,

    pub const Request = struct { op: u32, page: PageId };
    pub const Completion = struct { op: u32, page: PageId, err: ?BufferPool.Error };

    pub fn init(pool: *BufferPool, seed: u64) SimDisk {
        return .{ .pool = pool, .rng = .init(seed) };
    }

    pub fn deinit(self: *SimDisk, gpa: Allocator) void {
        self.pending.deinit(gpa);
        self.* = undefined;
    }

    /// Queue a read. Returns immediately; nothing is read yet.
    pub fn submit(self: *SimDisk, gpa: Allocator, op: u32, page: PageId) Allocator.Error!void {
        try self.pending.append(gpa, .{ .op = op, .page = page });
    }

    /// Complete one pending read, chosen pseudo-randomly: the page is read
    /// into the buffer pool and left there unpinned. This call stands for the
    /// kernel (or an I/O thread) finishing a request while the database
    /// thread was doing something else.
    pub fn completeOne(self: *SimDisk) Completion {
        assert(self.pending.items.len > 0);
        const i: usize = @intCast(self.rng.below(self.pending.items.len));
        const req = self.pending.orderedRemove(i);
        self.completions += 1;
        _ = self.pool.fetchPage(req.page) catch |err| return .{ .op = req.op, .page = req.page, .err = err };
        self.pool.unpin(req.page, false);
        return .{ .op = req.op, .page = req.page, .err = null };
    }
};

pub const Scheduler = struct {
    gpa: Allocator,
    tree: *DiskBTree,
    disk: SimDisk,
    slots: std.ArrayList(Slot) = .empty,
    /// Slots before this index have been admitted.
    admitted: usize = 0,
    readers_in_flight: u32 = 0,
    writer_in_flight: bool = false,
    insert_options: resumable.Options = .{},

    /// `step` calls made, and how many of them returned `.io`.
    steps: u64 = 0,
    yields: u64 = 0,
    /// Suspensions of finished inserts, by state.
    suspended: [resumable.suspend_points]u64 = @splat(0),
    /// When set, every scheduling decision is appended here (for the demo).
    events: ?*std.ArrayList(Event) = null,

    pub const Op = union(enum) { insert: InsertOp, get: GetOp };
    pub const Status = enum { queued, waiting, done, failed };
    pub const Slot = struct { op: Op, status: Status = .queued, err: ?resumable.Error = null };

    pub const Event = struct {
        kind: enum { admit, yield, complete, done, failed },
        op: u32,
        page: PageId = btree.invalid_page_id,
    };

    pub fn init(gpa: Allocator, tree: *DiskBTree, seed: u64) Scheduler {
        return .{ .gpa = gpa, .tree = tree, .disk = .init(tree.pool, seed) };
    }

    pub fn deinit(self: *Scheduler) void {
        for (self.slots.items) |*slot| switch (slot.op) {
            .insert => |*op| op.deinit(),
            .get => |*op| op.deinit(),
        };
        self.slots.deinit(self.gpa);
        self.disk.deinit(self.gpa);
        self.* = undefined;
    }

    /// Queue an insert; returns its ticket. `op_gpa` backs the operation's
    /// arena (the tests pass a failing allocator here).
    pub fn submitInsert(self: *Scheduler, op_gpa: Allocator, key: []const u8, value: []const u8) resumable.Error!u32 {
        try self.slots.ensureUnusedCapacity(self.gpa, 1);
        const op: InsertOp = try .init(op_gpa, self.tree, key, value, self.insert_options);
        self.slots.appendAssumeCapacity(.{ .op = .{ .insert = op } });
        return @intCast(self.slots.items.len - 1);
    }

    pub fn submitGet(self: *Scheduler, op_gpa: Allocator, key: []const u8) resumable.Error!u32 {
        try self.slots.ensureUnusedCapacity(self.gpa, 1);
        const op: GetOp = try .init(op_gpa, self.tree, key);
        self.slots.appendAssumeCapacity(.{ .op = .{ .get = op } });
        return @intCast(self.slots.items.len - 1);
    }

    /// The answer of a finished `get` (valid until `deinit`).
    pub fn result(self: *const Scheduler, ticket: u32) ?[]const u8 {
        assert(self.slots.items[ticket].status == .done);
        return self.slots.items[ticket].op.get.value;
    }

    /// Run every submitted operation to its end. An operation that fails is
    /// marked `.failed` with its error; the others go on. The only error
    /// returned from here is the scheduler's own (out of memory).
    pub fn run(self: *Scheduler) Allocator.Error!void {
        while (true) {
            try self.admit();
            if (self.disk.pending.items.len == 0) break;
            // Nothing can run: every admitted operation waits for a page.
            const c = self.disk.completeOne();
            try self.note(.{ .kind = .complete, .op = c.op, .page = c.page });
            if (c.err) |err| {
                switch (self.slots.items[c.op].op) {
                    .insert => |*op| op.cancel(),
                    .get => {},
                }
                try self.retire(c.op, err);
            } else {
                // Wake the operation NOW, before any other completion can
                // push its page out of a small pool again. This is what
                // guarantees progress: every completed read is followed by
                // at least one transition of the operation that asked.
                try self.drive(c.op);
            }
        }
        assert(self.admitted == self.slots.items.len);
        assert(self.readers_in_flight == 0 and !self.writer_in_flight);
    }

    /// Admit queued operations in submission order while the rule allows:
    /// readers share, a writer is alone.
    fn admit(self: *Scheduler) Allocator.Error!void {
        while (self.admitted < self.slots.items.len) {
            if (self.writer_in_flight) return;
            const i: u32 = @intCast(self.admitted);
            switch (self.slots.items[i].op) {
                .get => self.readers_in_flight += 1,
                .insert => {
                    if (self.readers_in_flight > 0) return;
                    self.writer_in_flight = true;
                },
            }
            self.admitted += 1;
            try self.note(.{ .kind = .admit, .op = i });
            try self.drive(i);
        }
    }

    /// Step operation `i` once: it runs until it is done or needs a page.
    fn drive(self: *Scheduler, i: u32) Allocator.Error!void {
        const pool = self.tree.pool;
        const reads_before = pool.pager.stats.reads;
        const outcome = switch (self.slots.items[i].op) {
            .insert => |*op| op.step(),
            .get => |*op| op.step(),
        };
        self.steps += 1;
        // The two promises of a resumable operation, checked on every call:
        assert(pool.pager.stats.reads == reads_before); // it read nothing
        assert(pool.pinnedFrames() == 0); // it kept no pin (R3)
        const s = outcome catch |err| return self.retire(i, err);
        switch (s) {
            .done => try self.retire(i, null),
            .io => |page| {
                self.yields += 1;
                self.slots.items[i].status = .waiting;
                try self.disk.submit(self.gpa, i, page);
                try self.note(.{ .kind = .yield, .op = i, .page = page });
            },
        }
    }

    fn retire(self: *Scheduler, i: u32, err: ?resumable.Error) Allocator.Error!void {
        const slot = &self.slots.items[i];
        slot.status = if (err == null) .done else .failed;
        slot.err = err;
        switch (slot.op) {
            .get => self.readers_in_flight -= 1,
            .insert => |*op| {
                self.writer_in_flight = false;
                for (&self.suspended, op.suspended) |*total, n| total.* += n;
            },
        }
        try self.note(.{ .kind = if (err == null) .done else .failed, .op = i });
    }

    fn note(self: *Scheduler, event: Event) Allocator.Error!void {
        if (self.events) |list| try list.append(self.gpa, event);
    }
};
