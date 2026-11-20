//! resumable.zig: `put` and `get` of the disk B+tree, rewritten so that they
//! never wait for the disk.
//!
//! The blocking `DiskBTree.put` calls `pool.fetchPage(id)`, and when the page
//! is not in memory that call sits inside `read()` until the disk answers.
//! Nothing else can run on that thread meanwhile. An engine that serves many
//! statements from one thread (Turso) cannot afford that, so its B-tree code
//! has this shape instead:
//!
//!     switch (op.step()) {
//!         .done => ...            // finished
//!         .io => |page| ...       // "I need this page. Call me again when
//!     }                           //  it is in the buffer pool."
//!
//! `step` returns to its caller instead of waiting, which means its local
//! variables are gone when it is called again. Everything the operation needs
//! to remember must therefore live in the operation object:
//!
//!   state   WHERE it stopped: an enum with one value per place that may
//!           need a page (the blocking code's program counter)
//!   path    the interior pages passed on the way down (the blocking code's
//!           local `path` list)
//!   carry   what the last split hands to the level above
//!   arena   the memory those two point into
//!
//! The rules that make re-entry safe (they are Turso's rules, see
//! turso/docs/agent-guides/async-io-model.md:113-160):
//!
//!   R1  A step asks for its page FIRST and changes nothing before that.
//!       If the page is missing it returns `.io` having done nothing, so
//!       calling it again, with or without the page, repeats nothing.
//!   R2  Whatever a step changes (a page, the path, the carry) it changes
//!       after its last yield point, and it records the new state in the
//!       same breath. No change is ever made twice.
//!   R3  No page stays pinned across a yield: every step unpins what it
//!       pinned before it returns. An operation that is abandoned while it
//!       waits therefore leaves nothing behind in the pool.
//!
//! What `step` does NOT avoid: writes. `pool.newPage` writes a zero page to
//! grow the file and may write a dirty victim back. A complete engine yields
//! there too; this chapter stops at reads to stay small (exercise 4).
const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const btree = @import("disk_btree.zig");
const DiskBTree = btree.DiskBTree;
const PageId = btree.PageId;
const PathEntry = DiskBTree.PathEntry;
const Carry = DiskBTree.Carry;

pub const Error = DiskBTree.Error;

/// What one call of `step` reports.
pub const Step = union(enum) {
    /// The operation is complete.
    done,
    /// The operation needs this page in the buffer pool. Nothing has been
    /// read: the caller arranges that, then calls `step` again.
    io: PageId,
};

/// Where an insert is. Each of the first seven states begins by asking for
/// exactly one page, so each is one possible suspension point.
pub const State = enum {
    /// Walking down: look at page `cur`, an interior page or the leaf.
    descend,
    /// Put the cell into leaf `cur`, if it fits.
    leaf_put,
    /// The full leaf is the root: move the root's content one level down.
    push_root_leaf,
    /// Split leaf `cur` around the new cell.
    split_leaf,
    /// Give `carry` to the parent on top of `path`.
    insert_separator,
    /// The full parent is the root: move its content one level down.
    push_root_interior,
    /// Split interior page `parent` around the separator of `carry`.
    split_interior,
    done,
    failed,
};

/// Number of states that can suspend (all but `done` and `failed`).
pub const suspend_points = 7;

/// Where the scratch memory of a split lives. `.step_buffer` is the WRONG
/// choice, kept to show what it does: see `InsertOp.leaveStep`.
pub const Scratch = enum { op_arena, step_buffer };

pub const Options = struct {
    scratch: Scratch = .op_arena,
    /// Testing knob: before every transition, drop every unpinned page from
    /// the pool, the worst an eviction policy could do to us. It turns every
    /// state into an actual suspension. (Turso has the same kind of knob:
    /// `inject_io_yield!`, turso/core/storage/btree.rs:3306-3309.)
    pressure: bool = false,
};

const step_buffer_size = 160 * 1024;

pub const InsertOp = struct {
    tree: *DiskBTree,
    /// The per-operation arena. It is created in `init`, survives every
    /// suspension, and is emptied when the operation completes or fails.
    /// `key`, `value`, `path` and `carry.sep` all point into it.
    arena: std.heap.ArenaAllocator,
    key: []const u8,
    value: []const u8,
    options: Options,

    state: State = .descend,
    /// The page the current state works on (descend, leaf_put, split_leaf).
    cur: PageId,
    path: std.ArrayList(PathEntry) = .empty,
    /// The parent being split (push_root_interior, split_interior).
    parent: PathEntry = undefined,
    carry: Carry = undefined,
    existed: bool = false,
    /// A page of the tree has been changed: failing now leaves it half-split.
    changed: bool = false,

    /// The page we last reported as missing, until we see it in the pool.
    waiting: ?PageId = null,
    /// How often each state returned `.io` (counted once per wait).
    suspended: [suspend_points]u32 = @splat(0),
    resumptions: u32 = 0,

    step_buf: []u8 = &.{},
    fba: std.heap.FixedBufferAllocator = undefined,

    /// Start an insert of (key, value). Both are COPIED into the operation's
    /// arena: the caller's buffers need not outlive this call, and usually do
    /// not, because the operation finishes many calls later.
    pub fn init(gpa: Allocator, tree: *DiskBTree, key: []const u8, value: []const u8, options: Options) Error!InsertOp {
        if (tree.poisoned) return error.TreePoisoned;
        if (key.len > btree.max_key_len) return error.KeyTooLarge;
        if (value.len > btree.max_value_len) return error.ValueTooLarge;
        var arena: std.heap.ArenaAllocator = .init(gpa);
        errdefer arena.deinit();
        const a = arena.allocator();
        var op: InsertOp = .{
            .tree = tree,
            .arena = undefined,
            .key = try a.dupe(u8, key),
            .value = try a.dupe(u8, value),
            .options = options,
            .cur = tree.root,
        };
        if (options.scratch == .step_buffer) {
            op.step_buf = try a.alloc(u8, step_buffer_size);
            op.fba = .init(op.step_buf);
        }
        // Moved in last: `a` points at the local `arena`, and the allocations
        // above changed its state.
        op.arena = arena;
        return op;
    }

    pub fn deinit(self: *InsertOp) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn finished(self: *const InsertOp) bool {
        return self.state == .done or self.state == .failed;
    }

    /// Run until the operation is complete or needs a page that is not in
    /// the pool. Never reads from the disk. On an error the operation is
    /// over (`state == .failed`), holds no pin and no memory, and has
    /// poisoned the tree if it had already changed a page.
    pub fn step(self: *InsertOp) Error!Step {
        assert(!self.finished());
        errdefer self.fail();
        if (self.tree.poisoned) return error.TreePoisoned;
        while (true) {
            if (self.options.pressure) _ = try self.tree.pool.evictUnpinned();
            switch (try self.advance()) {
                .again => {},
                .done => return .done,
                .io => |id| {
                    self.leaveStep();
                    return .{ .io = id };
                },
            }
        }
    }

    /// The caller gives up on the operation (its read failed, or the
    /// statement was cancelled). Same end state as an error inside `step`.
    pub fn cancel(self: *InsertOp) void {
        if (!self.finished()) self.fail();
    }

    const Advance = union(enum) { again, done, io: PageId };

    /// R1 in one place: is the page in the pool? If not, report it and
    /// count the suspension. `frameOf` only looks; it changes no statistics
    /// and no reference bits.
    fn need(self: *InsertOp, id: PageId) ?PageId {
        if (self.tree.pool.frameOf(id) != null) {
            if (self.waiting != null) self.resumptions += 1;
            self.waiting = null;
            return null;
        }
        if (self.waiting == null) self.suspended[@intFromEnum(self.state)] += 1;
        self.waiting = id;
        return id;
    }

    /// One transition of the state machine. Public so that tests can stop
    /// between any two transitions; everyone else calls `step`.
    ///
    /// Every arm has the same three parts, in this order:
    ///   1. `need`: return `.io` if the page is missing (nothing done yet)
    ///   2. one all-or-nothing step of chapter 12's `put`; the page it
    ///      fetches is in the pool, so the fetch cannot block
    ///   3. record what was learned and the next state
    pub fn advance(self: *InsertOp) Error!Advance {
        const tree = self.tree;
        const pool = tree.pool;
        switch (self.state) {
            .descend => {
                if (self.need(self.cur)) |id| return .{ .io = id };
                const id = self.cur;
                const page = try tree.pinNode(id);
                if (page.kind() == btree.kind_leaf) {
                    pool.unpin(id, false);
                    self.state = .leaf_put;
                    return .again;
                }
                const index = btree.childIndex(page, self.key);
                const child = btree.childAt(page, index);
                pool.unpin(id, false);
                // The path grows AFTER the yield point above (R2). Had the
                // append come first, every re-entry would add the same page
                // again: the bug of async-io-model.md:164-171.
                try self.path.append(self.arena.allocator(), .{ .id = id, .index = index });
                self.cur = child;
                return .again;
            },
            .leaf_put => {
                if (self.need(self.cur)) |id| return .{ .io = id };
                const id = self.cur;
                const leaf = try tree.pinNode(id);
                self.existed = leaf.search(self.key).found;
                if (leaf.put(self.key, self.value)) |_| {
                    pool.unpin(id, true);
                    return self.finish();
                } else |err| switch (err) {
                    error.CellTooLarge => unreachable, // excluded in `init`
                    error.PageFull => {
                        pool.unpin(id, false);
                        self.state = if (self.path.items.len == 0) .push_root_leaf else .split_leaf;
                        return .again;
                    },
                }
            },
            .push_root_leaf => {
                if (self.need(tree.root)) |id| return .{ .io = id };
                // Reserve the path slot first: after pushRootDown has changed
                // the root, nothing in this arm may fail.
                try self.path.ensureUnusedCapacity(self.arena.allocator(), 1);
                self.cur = try tree.pushRootDown();
                self.changed = true;
                self.path.appendAssumeCapacity(.{ .id = tree.root, .index = 0 });
                self.state = .split_leaf;
                return .again;
            },
            .split_leaf => {
                if (self.need(self.cur)) |id| return .{ .io = id };
                // `carry.sep` is a slice into the split's scratch memory. It
                // is read by the NEXT state, possibly many calls from now.
                self.carry = try tree.splitLeaf(self.scratch(), self.cur, self.key, self.value);
                self.changed = true;
                self.state = .insert_separator;
                return .again;
            },
            .insert_separator => {
                // Look at the top of the path but do not pop it yet: if we
                // yield here, the entry must still be there on re-entry.
                const parent = self.path.getLast();
                if (self.need(parent.id)) |id| return .{ .io = id };
                const fitted = try tree.insertSeparator(self.scratch(), parent, self.carry);
                _ = self.path.pop();
                if (fitted) return self.finish();
                self.parent = parent;
                self.state = if (self.path.items.len == 0) .push_root_interior else .split_interior;
                return .again;
            },
            .push_root_interior => {
                if (self.need(tree.root)) |id| return .{ .io = id };
                try self.path.ensureUnusedCapacity(self.arena.allocator(), 1);
                // The child index stays valid: the cells moved unchanged.
                self.parent.id = try tree.pushRootDown();
                self.path.appendAssumeCapacity(.{ .id = tree.root, .index = 0 });
                self.state = .split_interior;
                return .again;
            },
            .split_interior => {
                if (self.need(self.parent.id)) |id| return .{ .io = id };
                self.carry = try tree.splitInterior(self.scratch(), self.parent, self.carry);
                self.state = .insert_separator;
                return .again;
            },
            .done, .failed => unreachable,
        }
    }

    fn scratch(self: *InsertOp) Allocator {
        return switch (self.options.scratch) {
            .op_arena => self.arena.allocator(),
            .step_buffer => self.fba.allocator(),
        };
    }

    /// Called when `step` is about to return `.io`.
    ///
    /// With `.op_arena` there is nothing to do: that is the point of the
    /// arena. With `.step_buffer` the scratch memory is treated the way a
    /// stack frame is treated when its function returns: it is given up, and
    /// the next user overwrites it. (0xAA is what Zig's Debug mode writes
    /// into memory that became undefined.) `carry.sep` still points there.
    fn leaveStep(self: *InsertOp) void {
        if (self.options.scratch == .step_buffer) {
            @memset(self.step_buf, 0xAA);
            self.fba.reset();
        }
    }

    fn finish(self: *InsertOp) Advance {
        if (!self.existed) self.tree.key_count += 1;
        self.state = .done;
        self.release();
        return .done;
    }

    fn fail(self: *InsertOp) void {
        if (self.changed) self.tree.poisoned = true;
        self.state = .failed;
        self.release();
    }

    /// The end of the arena's lifetime: one call frees the key, the value,
    /// the path, every page copy and every cell list of every split.
    fn release(self: *InsertOp) void {
        _ = self.arena.reset(.free_all);
        self.key = &.{};
        self.value = &.{};
        self.path = .empty;
        self.step_buf = &.{};
    }
};

/// A resumable point lookup: the same descent, read-only. It exists so that
/// the scheduler has operations whose reads may interleave.
pub const GetOp = struct {
    tree: *DiskBTree,
    arena: std.heap.ArenaAllocator,
    key: []const u8,
    cur: PageId,
    is_done: bool = false,
    /// The answer, valid from `.done` until `deinit` (it lives in the arena).
    value: ?[]const u8 = null,
    waiting: ?PageId = null,
    suspended: u32 = 0,

    pub fn init(gpa: Allocator, tree: *DiskBTree, key: []const u8) Error!GetOp {
        if (tree.poisoned) return error.TreePoisoned;
        var arena: std.heap.ArenaAllocator = .init(gpa);
        errdefer arena.deinit();
        const owned = try arena.allocator().dupe(u8, key);
        return .{ .tree = tree, .arena = arena, .key = owned, .cur = tree.root };
    }

    pub fn deinit(self: *GetOp) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn step(self: *GetOp) Error!Step {
        assert(!self.is_done);
        const tree = self.tree;
        if (tree.poisoned) return error.TreePoisoned;
        while (true) {
            const id = self.cur;
            if (tree.pool.frameOf(id) == null) {
                if (self.waiting == null) self.suspended += 1;
                self.waiting = id;
                return .{ .io = id };
            }
            self.waiting = null;
            const page = try tree.pinNode(id);
            defer tree.pool.unpin(id, false);
            if (page.kind() == btree.kind_leaf) {
                // Copy the value out: the page may be evicted as soon as it
                // is unpinned, long before the caller looks at the answer.
                if (page.get(self.key)) |v| self.value = try self.arena.allocator().dupe(u8, v);
                self.is_done = true;
                return .done;
            }
            self.cur = btree.childAt(page, btree.childIndex(page, self.key));
        }
    }
};
