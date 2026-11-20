// Copied from chapters/12-disk-backed-bplus-tree/zig/src/disk_btree.zig. Changes for chapter 30, none of
// which alters what `put` does or which bytes reach the file:
//   * the steps of `put` (pinNode, pushRootDown, splitLeaf, insertSeparator, splitInterior) and the
//     types they exchange (PathEntry, Carry) are `pub`, so that resumable.zig can call them one by one;
//   * splitLeaf, insertSeparator and splitInterior take their scratch allocator as a parameter instead
//     of using the tree's arena: a resumable operation brings its own arena, which must outlive the call.
//! disk_btree.zig: a B+tree whose nodes are slotted pages in a file.
//!
//! Layers (each one only talks to the one below):
//!
//!   DiskBTree      this file: keys, splits, the tree shape
//!   SlottedPage    base_slotted_page.zig: cells inside one 4096-byte page
//!   BufferPool     base_buffer_pool.zig: page id -> pinned frame in memory
//!   Pager          base_pager.zig: page id -> byte offset in the storage
//!   Storage        base_storage.zig: a file, or memory with fault injection
//!
//! File layout
//! ===========
//!
//!   page 0   metapage (see `Meta`)
//!   page 1   the root, for the whole life of the file
//!   page 2+  leaves and interior pages, in order of allocation
//!
//! Every tree page is a slotted page formatted with a 4-byte reserved tail
//! (bytes 4092..4095 stay zero; chapters 21 and 22 put a page checksum there).
//! The slotted page's caller-owned header bytes hold what makes it a node:
//!
//!   kind        1 = leaf, 2 = interior
//!   user area   bytes 0..4: one page id (u32, little-endian), the "link"
//!                 leaf:      the right sibling, or invalid_page_id for none
//!                 interior:  the rightmost child
//!
//!   leaf cell      key -> value
//!   interior cell  key -> child page id (4 bytes). Cell i is (K_i, C_i):
//!                  C_i holds the keys k with K_(i-1) <= k < K_i, and the
//!                  rightmost child (the link) holds the keys >= K_(n-1).
//!
//! So a key equal to a separator lives to the RIGHT of it, the convention of
//! chapter 07, and an interior page with n cells has n + 1 children.
//!
//! Invariants (checked by `validate`)
//!   T1  every page is a well-formed slotted page of a known kind
//!   T2  keys are strictly ascending inside a page (the slotted page's rule)
//!   T3  every key of a subtree lies inside the bounds its ancestors'
//!       separators give it: lower bound inclusive, upper bound exclusive
//!   T4  all leaves are at the same depth
//!   T5  following the links from the leftmost leaf visits every leaf once,
//!       in key order, and ends with invalid_page_id
//!   T6  every page of the file except page 0 is reached exactly once
//!   T7  only the root may be an empty leaf; an interior page has >= 1 key
//!   T8  the number of keys in the leaves equals `key_count`
//!
//! Pins. No pin outlives the function that took it, and at most TWO pages are
//! pinned at any moment (the two halves of a split, or the root and the page
//! its content moves to). The pool therefore needs only 2 frames to work.
//! The path from the root is remembered as page ids, not as pinned pages.
//!
//! Memory. The tree allocates nothing per node: nodes live in the pool's
//! frame slab. Each operation gets scratch memory (the path stack, the copy
//! of a page being split, cell lists) from one ArenaAllocator that is reset
//! when the operation returns.
//!
//! NOT crash-safe, and not error-atomic. A split changes two or three pages
//! and the file only ever receives them one at a time. If `put` fails after
//! its first page change (I/O error, out of memory), the tree in memory is
//! half-split: the handle marks itself poisoned. From then on `put`, `get`,
//! `range` and `flush` (and so `close`) return `TreePoisoned`, so nothing is
//! read through the broken tree and nothing more of it is written. `validate`,
//! `height` and `dump` do not check the flag: they are how the damage is
//! looked at. Neither does `RangeIterator.next`, so a scan must not be
//! continued across a `put` (its position is stale after any put anyway).
//! If the process dies between the page writes, the file is half-split.
//! Chapters 21 and 22 repair this with checksums and a write-ahead log.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const pager_mod = @import("base_pager.zig");
const pool_mod = @import("base_buffer_pool.zig");
const slotted = @import("base_slotted_page.zig");
const SlottedPage = slotted.SlottedPage;
const BufferPool = pool_mod.BufferPool;

pub const Page = pager_mod.Page;
pub const PageId = pager_mod.PageId;
pub const page_size = pager_mod.page_size;
pub const invalid_page_id = pager_mod.invalid_page_id;

pub const meta_page_id: PageId = 0;
pub const magic = "BTREE12\x00";
pub const format_version: u32 = 1;
/// Bytes at the end of every page that the tree never touches.
pub const reserved_tail = 4;

pub const kind_leaf: u8 = 1;
pub const kind_interior: u8 = 2;

/// Bytes an empty tree page offers to cells and their slots.
pub const page_capacity = page_size - reserved_tail - slotted.header_size;
pub const max_key_len = 256;
pub const max_value_len = page_size / 4;

/// What a cell costs its page: the cell itself plus its slot.
pub fn cellCost(key_len: usize, value_len: usize) usize {
    return slotted.cellSize(key_len, value_len) + slotted.slot_size;
}

comptime {
    // The split argument (see `splitPoint`) needs every cell to cost at most
    // a third of a page: then a page that overflowed can always be cut into
    // two pages that both fit. Postgres has the same rule for the same reason.
    assert(3 * cellCost(max_key_len, max_value_len) <= page_capacity);
    assert(slotted.user_area_size >= @sizeOf(PageId));
}

/// The metapage, page 0. Little-endian, like every integer on disk.
///
///    0  [8]  magic "BTREE12\0"
///    8  u32  format version (1)
///   12  u32  page size (4096)
///   16  u32  root page id (always 1 in this chapter; stored so that later
///            formats, or several trees in one file, can differ)
///   20  u32  page count  } as of the last `flush`; between flushes the
///   24  u64  key count   } file can be ahead of them
///   ..       zero; the last 4 bytes are reserved like on every other page
pub const Meta = struct {
    root: PageId,
    page_count: u32,
    key_count: u64,

    fn encode(self: Meta, buf: *Page) void {
        @memset(buf, 0);
        @memcpy(buf[0..8], magic);
        std.mem.writeInt(u32, buf[8..12], format_version, .little);
        std.mem.writeInt(u32, buf[12..16], page_size, .little);
        std.mem.writeInt(u32, buf[16..20], self.root, .little);
        std.mem.writeInt(u32, buf[20..24], self.page_count, .little);
        std.mem.writeInt(u64, buf[24..32], self.key_count, .little);
    }

    fn decode(buf: *const Page) error{ BadMagic, UnsupportedVersion }!Meta {
        if (!std.mem.eql(u8, buf[0..8], magic)) return error.BadMagic;
        if (std.mem.readInt(u32, buf[8..12], .little) != format_version) return error.UnsupportedVersion;
        if (std.mem.readInt(u32, buf[12..16], .little) != page_size) return error.UnsupportedVersion;
        return .{
            .root = std.mem.readInt(u32, buf[16..20], .little),
            .page_count = std.mem.readInt(u32, buf[20..24], .little),
            .key_count = std.mem.readInt(u64, buf[24..32], .little),
        };
    }
};

// ---- a slotted page seen as a tree node ------------------------------------

/// The page id in the user area: right sibling (leaf) or rightmost child.
pub fn link(page: SlottedPage) PageId {
    return std.mem.readInt(u32, page.userArea()[0..4], .little);
}

fn setLink(page: SlottedPage, id: PageId) void {
    std.mem.writeInt(u32, page.userArea()[0..4], id, .little);
}

/// Child `i` of an interior page, 0 <= i <= count (count = the rightmost).
pub fn childAt(page: SlottedPage, i: usize) PageId {
    if (i == page.count()) return link(page);
    return std.mem.readInt(u32, page.value(i)[0..4], .little);
}

/// Which child of an interior page leads to `key`: the first cell whose key
/// is greater than `key`, or the rightmost child if there is none. A key
/// equal to a separator goes right of it.
pub fn childIndex(page: SlottedPage, key: []const u8) usize {
    const r = page.search(key);
    return if (r.found) r.index + 1 else r.index;
}

fn childBytes(id: PageId) [4]u8 {
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, id, .little);
    return b;
}

/// Cut a list of cell costs in two "50/50 by bytes": the left part is the
/// shortest prefix that holds at least half of the bytes. Returns its length
/// k, with 1 <= k <= costs.len - min_right.
///
/// Why both halves fit. A page overflowed, so the costs add up to T with
/// capacity < T <= capacity + m, where m is the largest cost allowed. The
/// prefix of length k - 1 is below T/2, so the left half is below T/2 + m
/// <= capacity/2 + 3m/2, which is <= capacity because m <= capacity/3. The
/// right half is at most T/2. The same T > capacity with m <= capacity/3
/// means there are at least 4 cells, so neither half is empty.
pub fn splitPoint(costs: []const usize, min_right: usize) usize {
    var total: usize = 0;
    for (costs) |c| total += c;
    const last = costs.len - min_right;
    var left: usize = 0;
    for (costs[0..last], 1..) |c, k| {
        left += c;
        if (2 * left >= total) return k;
    }
    return last;
}

pub const DiskBTree = struct {
    /// Borrowed: the caller owns the pool (and the pager under it).
    pool: *BufferPool,
    /// Scratch memory of the operation in progress; reset when it returns.
    arena: std.heap.ArenaAllocator,
    root: PageId,
    key_count: u64,
    /// Set when a `put` failed between two page changes of a split. Checked
    /// by `put`, `get`, `range` and `flush`; not by `validate`, `height`,
    /// `dump` or a `RangeIterator` that already exists.
    poisoned: bool = false,
    stats: Stats = .{},

    pub const Stats = struct {
        leaf_splits: u64 = 0,
        interior_splits: u64 = 0,
        /// Times the root's content moved down one level (the height grew).
        root_splits: u64 = 0,
    };

    pub const Error = BufferPool.Error || Allocator.Error || error{
        /// `create` on a storage that already has pages.
        NotEmpty,
        /// `open`: page 0 is not a metapage of this format.
        BadMagic,
        UnsupportedVersion,
        /// A page is not what the tree expects there (wrong kind, a link
        /// that leaves the file, a metapage that contradicts the file).
        Corrupt,
        KeyTooLarge,
        ValueTooLarge,
        /// An earlier `put` failed half-way through a split.
        TreePoisoned,
    };

    pub const ValidateError = error{
        BadPage, // T1, T2
        KeyOutOfBounds, // T3
        UnevenDepth, // T4
        LeafChainBroken, // T5
        PageReachedTwice, // T6
        UnreachablePage, // T6
        EmptyPage, // T7
        KeyCountMismatch, // T8
    };

    pub const PathEntry = struct { id: PageId, index: usize };
    /// What a split hands to the level above: `left` kept the keys below
    /// `sep`, the new page `right` got the keys from `sep` on.
    pub const Carry = struct { sep: []const u8, left: PageId, right: PageId };
    const Cell = struct { key: []const u8, value: []const u8 };
    const Entry = struct { key: []const u8, child: PageId };

    // ---- create / open / close ----------------------------------------------

    /// Format an empty storage: metapage on page 0, an empty leaf as the root
    /// on page 1. Both are written and synced before this returns.
    pub fn create(gpa: Allocator, pool: *BufferPool) Error!DiskBTree {
        if (pool.pager.pageCount() != 0) return error.NotEmpty;
        const meta = try pool.newPage();
        pool.unpin(meta.id, true);
        const root = try pool.newPage();
        const page = SlottedPage.initReserved(root.page, reserved_tail);
        page.setKind(kind_leaf);
        setLink(page, invalid_page_id);
        pool.unpin(root.id, true);
        assert(meta.id == meta_page_id and root.id == 1);

        var tree: DiskBTree = .{ .pool = pool, .arena = .init(gpa), .root = root.id, .key_count = 0 };
        errdefer tree.deinit();
        try tree.flush();
        return tree;
    }

    /// Open an existing tree. Only the metapage is read here.
    pub fn open(gpa: Allocator, pool: *BufferPool) Error!DiskBTree {
        const pages = pool.pager.pageCount();
        if (pages < 2) return error.BadMagic;
        const buf = try pool.fetchPage(meta_page_id);
        defer pool.unpin(meta_page_id, false);
        const meta = try Meta.decode(buf);
        // A file with MORE pages than the metapage says was not flushed
        // after its last allocation; `validate` will find the orphans. A
        // file with fewer pages has lost part of the tree.
        if (meta.root == meta_page_id or meta.root >= pages or meta.page_count > pages) return error.Corrupt;
        return .{ .pool = pool, .arena = .init(gpa), .root = meta.root, .key_count = meta.key_count };
    }

    /// Free the scratch arena. Does not flush: see `close`.
    pub fn deinit(self: *DiskBTree) void {
        self.arena.deinit();
        self.* = undefined;
    }

    /// Bring the file up to date: write the metapage, write every dirty
    /// page, sync. The pages go out one after the other, in frame order, so
    /// a crash in the middle leaves a mix of old and new pages.
    pub fn flush(self: *DiskBTree) Error!void {
        if (self.poisoned) return error.TreePoisoned;
        const buf = try self.pool.fetchPage(meta_page_id);
        const meta: Meta = .{ .root = self.root, .page_count = self.pool.pager.pageCount(), .key_count = self.key_count };
        meta.encode(buf);
        self.pool.unpin(meta_page_id, true);
        try self.pool.flushAll();
    }

    /// `flush`, then `deinit` (also when the flush fails).
    pub fn close(self: *DiskBTree) Error!void {
        defer self.deinit();
        try self.flush();
    }

    // ---- get ----------------------------------------------------------------

    /// The value stored under `key`, copied with `allocator` (the caller
    /// frees it), or null. A copy, because the page it lives on may be
    /// evicted as soon as this function has unpinned it.
    pub fn get(self: *DiskBTree, allocator: Allocator, key: []const u8) Error!?[]u8 {
        if (self.poisoned) return error.TreePoisoned;
        const leaf_id = try self.findLeaf(key, null);
        const leaf = try self.pinNode(leaf_id);
        defer self.pool.unpin(leaf_id, false);
        const value = leaf.get(key) orelse return null;
        return try allocator.dupe(u8, value);
    }

    /// Walk from the root to the leaf that owns `key`, one pin at a time: a
    /// parent is unpinned before its child is fetched, which is fine without
    /// concurrency (chapter 19 is about when it is not). If `path` is given,
    /// the interior pages passed and the child index taken in each are
    /// appended to it. Returns the leaf's page id, not pinned.
    fn findLeaf(self: *DiskBTree, key: []const u8, path: ?*std.ArrayList(PathEntry)) Error!PageId {
        var id = self.root;
        while (true) {
            const page = try self.pinNode(id);
            if (page.kind() == kind_leaf) {
                self.pool.unpin(id, false);
                return id;
            }
            const index = childIndex(page, key);
            const child = childAt(page, index);
            self.pool.unpin(id, false);
            if (path) |p| try p.append(self.arena.allocator(), .{ .id = id, .index = index });
            id = child;
        }
    }

    /// Fetch and pin page `id` as a tree node. A page that is not a node of
    /// this tree (for example a page of zeroes that a crash left behind) is
    /// reported as `Corrupt` and not pinned.
    pub fn pinNode(self: *DiskBTree, id: PageId) Error!SlottedPage {
        if (id == meta_page_id or id >= self.pool.pager.pageCount()) return error.Corrupt;
        const page = SlottedPage.open(try self.pool.fetchPage(id));
        const known = page.kind() == kind_leaf or page.kind() == kind_interior;
        if (!known or page.reservedSize() != reserved_tail) {
            self.pool.unpin(id, false);
            return error.Corrupt;
        }
        return page;
    }

    // ---- put ----------------------------------------------------------------

    /// Insert `key`, or replace its value if it is already there.
    pub fn put(self: *DiskBTree, key: []const u8, value: []const u8) Error!void {
        if (self.poisoned) return error.TreePoisoned;
        if (key.len > max_key_len) return error.KeyTooLarge;
        if (value.len > max_value_len) return error.ValueTooLarge;
        defer _ = self.arena.reset(.retain_capacity);

        var path: std.ArrayList(PathEntry) = .empty;
        const leaf_id = try self.findLeaf(key, &path);
        const leaf = try self.pinNode(leaf_id);
        const existed = leaf.search(key).found;
        if (leaf.put(key, value)) |_| {
            // The common case: one page changed, in memory.
            self.pool.unpin(leaf_id, true);
        } else |err| switch (err) {
            error.CellTooLarge => unreachable, // excluded by the length checks
            error.PageFull => {
                self.pool.unpin(leaf_id, false);
                try self.splitAndInsert(&path, leaf_id, key, value);
            },
        }
        if (!existed) self.key_count += 1;
    }

    /// The leaf `leaf_id` has no room for (key, value). Split it, then hand
    /// the separator to the parent; if the parent has no room either, split
    /// that too, and so on up the remembered path. Splits therefore run
    /// bottom-up: only now, at the leaf, do we know that a split is needed
    /// and how many bytes the parent must take.
    fn splitAndInsert(self: *DiskBTree, path: *std.ArrayList(PathEntry), leaf_id: PageId, key: []const u8, value: []const u8) Error!void {
        const scratch = self.arena.allocator();
        // Each step below is all-or-nothing by itself, but the steps are
        // not atomic together. Once one has changed a page, a failure in a
        // later one leaves the tree half-split.
        var changed = false;
        errdefer if (changed) {
            self.poisoned = true;
        };

        var id = leaf_id;
        if (path.items.len == 0) {
            // The leaf is the root. The root never splits: its content
            // moves down first, and the page below it splits.
            id = try self.pushRootDown();
            changed = true;
            try path.append(scratch, .{ .id = self.root, .index = 0 });
        }
        var carry = try self.splitLeaf(scratch, id, key, value);
        changed = true;

        while (true) {
            var parent = path.pop().?;
            if (try self.insertSeparator(scratch, parent, carry)) return;
            if (path.items.len == 0) {
                // The full parent is the root: same move, one level up. The
                // child index stays valid because the cells moved unchanged.
                parent.id = try self.pushRootDown();
                try path.append(scratch, .{ .id = self.root, .index = 0 });
            }
            carry = try self.splitInterior(scratch, parent, carry);
        }
    }

    /// Grow the tree by one level WITHOUT changing the root's page id: copy
    /// the root page into a new page and turn the root into an interior page
    /// with no key and that new page as its only (rightmost) child. Returns
    /// the new page, which the caller then splits like any other page.
    /// Fails before changing anything.
    pub fn pushRootDown(self: *DiskBTree) Error!PageId {
        const root = try self.pool.fetchPage(self.root);
        errdefer self.pool.unpin(self.root, false);
        const child = try self.pool.newPage();
        // A slotted page has no pointers into itself, only offsets, so its
        // bytes mean the same thing at any page id.
        child.page.* = root.*;
        const page = SlottedPage.initReserved(root, reserved_tail);
        page.setKind(kind_interior);
        setLink(page, child.id);
        self.pool.unpin(child.id, true);
        self.pool.unpin(self.root, true);
        self.stats.root_splits += 1;
        return child.id;
    }

    /// Split leaf `id` around the new cell. The left half stays on page
    /// `id`, so the leaf that pointed at it still does; the right half goes
    /// to a new page and is linked in after it. Fails before changing
    /// anything.
    pub fn splitLeaf(self: *DiskBTree, scratch: Allocator, id: PageId, key: []const u8, value: []const u8) Error!Carry {
        const left_buf = try self.pool.fetchPage(id);
        errdefer self.pool.unpin(id, false);

        // The split buffer: a copy of the page, so that both halves can be
        // rebuilt from it. The cells below are slices into this copy.
        const copy = try scratch.create(Page);
        copy.* = left_buf.*;
        const old = SlottedPage.open(copy);
        const r = old.search(key);
        const n = old.count() + @intFromBool(!r.found);
        const cells = try scratch.alloc(Cell, n);
        const costs = try scratch.alloc(usize, n);
        for (cells, costs, 0..) |*cell, *cost, i| {
            // Slot i of the result: the old cells with the new one inserted
            // at r.index, or put in place of the old cell with the same key.
            if (i == r.index) {
                cell.* = .{ .key = key, .value = value };
            } else {
                const from = if (i < r.index or r.found) i else i - 1;
                cell.* = .{ .key = old.key(from), .value = old.value(from) };
            }
            cost.* = cellCost(cell.key.len, cell.value.len);
        }
        const k = splitPoint(costs, 1);

        const right = try self.pool.newPage(); // the last step that can fail
        writeLeaf(left_buf, right.id, cells[0..k]);
        writeLeaf(right.page, link(old), cells[k..]);
        self.pool.unpin(right.id, true);
        self.pool.unpin(id, true);
        self.stats.leaf_splits += 1;
        // The separator is a COPY of the right half's first key: in a B+tree
        // the key itself stays in the leaf.
        return .{ .sep = cells[k].key, .left = id, .right = right.id };
    }

    /// Record a finished split in the parent: where one pointer led to
    /// `carry.left`, there are now `left`, the separator and `right`.
    /// Returns false, with the parent untouched, if the separator does not
    /// fit.
    pub fn insertSeparator(self: *DiskBTree, scratch: Allocator, parent: PathEntry, carry: Carry) Error!bool {
        const page = try self.pinNode(parent.id);
        errdefer self.pool.unpin(parent.id, false);
        if (page.kind() != kind_interior or parent.index > page.count()) return error.Corrupt;
        if (childAt(page, parent.index) != carry.left) return error.Corrupt;
        if (!page.fits(carry.sep.len, @sizeOf(PageId))) {
            self.pool.unpin(parent.id, false);
            return false;
        }
        // The pointer that led to `left` must now lead to `right`...
        if (parent.index == page.count()) {
            setLink(page, carry.right);
        } else {
            // (same-size overwrite: happens in place and cannot fail; the
            // key is copied because `put` takes no slice of its own page)
            const old_key = try scratch.dupe(u8, page.key(parent.index));
            page.put(old_key, &childBytes(carry.right)) catch unreachable;
        }
        // ...and the new cell (sep -> left) goes in front of it.
        page.insertAt(parent.index, carry.sep, &childBytes(carry.left)) catch unreachable;
        self.pool.unpin(parent.id, true);
        return true;
    }

    /// Split interior page `parent.id` while inserting the separator of
    /// `carry` at `parent.index`. Unlike in a leaf, the middle key MOVES up:
    /// it separates the two halves and is needed in neither. Fails before
    /// changing anything.
    pub fn splitInterior(self: *DiskBTree, scratch: Allocator, parent: PathEntry, carry: Carry) Error!Carry {
        const id = parent.id;
        const left_buf = try self.pool.fetchPage(id);
        errdefer self.pool.unpin(id, false);

        const copy = try scratch.create(Page);
        copy.* = left_buf.*;
        const old = SlottedPage.open(copy);
        const n = old.count() + 1;
        const entries = try scratch.alloc(Entry, n);
        const costs = try scratch.alloc(usize, n);
        var rightmost = link(old);
        for (entries, costs, 0..) |*entry, *cost, i| {
            entry.* = if (i < parent.index)
                .{ .key = old.key(i), .child = childAt(old, i) }
            else if (i == parent.index)
                .{ .key = carry.sep, .child = carry.left }
            else
                .{ .key = old.key(i - 1), .child = childAt(old, i - 1) };
            cost.* = cellCost(entry.key.len, @sizeOf(PageId));
        }
        // The pointer after the new separator is the one that led to `left`.
        if (parent.index + 1 < n) entries[parent.index + 1].child = carry.right else rightmost = carry.right;

        // entries[k] moves up; at least one entry must remain right of it.
        const k = splitPoint(costs, 2);

        const right = try self.pool.newPage(); // the last step that can fail
        writeInterior(left_buf, entries[k].child, entries[0..k]);
        writeInterior(right.page, rightmost, entries[k + 1 ..]);
        self.pool.unpin(right.id, true);
        self.pool.unpin(id, true);
        self.stats.interior_splits += 1;
        return .{ .sep = entries[k].key, .left = id, .right = right.id };
    }

    fn writeLeaf(buf: *Page, next: PageId, cells: []const Cell) void {
        const page = SlottedPage.initReserved(buf, reserved_tail);
        page.setKind(kind_leaf);
        setLink(page, next);
        for (cells, 0..) |cell, i| page.insertAt(i, cell.key, cell.value) catch unreachable; // see splitPoint
    }

    fn writeInterior(buf: *Page, rightmost: PageId, entries: []const Entry) void {
        const page = SlottedPage.initReserved(buf, reserved_tail);
        page.setKind(kind_interior);
        setLink(page, rightmost);
        for (entries, 0..) |entry, i| page.insertAt(i, entry.key, &childBytes(entry.child)) catch unreachable;
    }

    // ---- range --------------------------------------------------------------

    /// Iterate over the entries with lo <= key < hi in key order; `hi` null
    /// means "to the end". `lo` = "" starts at the first key.
    pub fn range(self: *DiskBTree, lo: []const u8, hi: ?[]const u8) Error!RangeIterator {
        if (self.poisoned) return error.TreePoisoned;
        const leaf_id = try self.findLeaf(lo, null);
        const leaf = try self.pinNode(leaf_id);
        defer self.pool.unpin(leaf_id, false);
        return .{ .tree = self, .leaf = leaf_id, .slot = leaf.search(lo).index, .hi = hi };
    }

    /// A position in the leaf level: (leaf page id, slot). It holds no pin
    /// between calls, so there is nothing to release; each `next` pins the
    /// leaf, copies one entry into the iterator's own buffers and unpins.
    /// The tree must not be modified while an iterator is in use (a split
    /// would move the entries under it; chapter 08 shows what a cursor must
    /// do to survive that).
    pub const RangeIterator = struct {
        tree: *DiskBTree,
        leaf: PageId,
        slot: usize,
        /// Borrowed from the caller of `range`.
        hi: ?[]const u8,
        key_buf: [max_key_len]u8 = undefined,
        value_buf: [max_value_len]u8 = undefined,

        pub const Item = struct { key: []const u8, value: []const u8 };

        /// The next entry, or null at the end. The slices are valid until
        /// the next call.
        pub fn next(self: *RangeIterator) Error!?Item {
            while (self.leaf != invalid_page_id) {
                const pinned = self.leaf; // `self.leaf` may move on below
                const page = try self.tree.pinNode(pinned);
                defer self.tree.pool.unpin(pinned, false);
                if (page.kind() != kind_leaf) return error.Corrupt;
                if (self.slot < page.count()) {
                    const key = page.key(self.slot);
                    if (self.hi) |hi| {
                        if (std.mem.order(u8, key, hi) != .lt) {
                            self.leaf = invalid_page_id;
                            return null;
                        }
                    }
                    const value = page.value(self.slot);
                    @memcpy(self.key_buf[0..key.len], key);
                    @memcpy(self.value_buf[0..value.len], value);
                    self.slot += 1;
                    return .{ .key = self.key_buf[0..key.len], .value = self.value_buf[0..value.len] };
                }
                // End of this leaf: follow the sibling link. No parent is
                // needed, which is the point of chaining the leaves.
                self.leaf = link(page);
                self.slot = 0;
            }
            return null;
        }
    };

    // ---- validate -------------------------------------------------------------

    /// Check invariants T1 to T8 (see the top of the file) by reading every
    /// page of the file.
    pub fn validate(self: *DiskBTree) (Error || ValidateError)!void {
        defer _ = self.arena.reset(.retain_capacity);
        const scratch = self.arena.allocator();
        var walk: Walk = .{
            .tree = self,
            .seen = try .initEmpty(scratch, self.pool.pager.pageCount()),
        };
        walk.seen.set(meta_page_id);
        try walk.visit(self.root, null, null, 0);

        for (walk.leaves.items, 1..) |leaf, i| {
            const expected = if (i < walk.leaves.items.len) walk.leaves.items[i].id else invalid_page_id;
            if (leaf.next != expected) return error.LeafChainBroken; // T5
        }
        if (walk.seen.count() != walk.seen.bit_length) return error.UnreachablePage; // T6
        if (walk.keys != self.key_count) return error.KeyCountMismatch; // T8
    }

    const Walk = struct {
        tree: *DiskBTree,
        seen: std.DynamicBitSetUnmanaged,
        /// The leaves in the order the tree reaches them, with their links.
        leaves: std.ArrayList(struct { id: PageId, next: PageId }) = .empty,
        leaf_depth: ?usize = null,
        keys: u64 = 0,

        /// `lo` (inclusive) and `hi` (exclusive) are the bounds the
        /// ancestors' separators put on this subtree; null = unbounded.
        fn visit(w: *Walk, id: PageId, lo: ?[]const u8, hi: ?[]const u8, depth: usize) (Error || ValidateError)!void {
            const pool = w.tree.pool;
            const scratch = w.tree.arena.allocator();
            if (id >= w.seen.bit_length) return error.BadPage;
            if (w.seen.isSet(id)) return error.PageReachedTwice; // T6
            w.seen.set(id);

            const buf = try pool.fetchPage(id);
            var pinned = true;
            defer if (pinned) pool.unpin(id, false);
            var page = SlottedPage.open(buf);
            // `SlottedPage.validate` is safe on any bytes; everything after
            // it may trust the page.
            page.validate() catch return error.BadPage; // T1, T2
            if (page.reservedSize() != reserved_tail) return error.BadPage;
            const n = page.count();
            if (n > 0) {
                if (lo) |bound| if (std.mem.order(u8, page.key(0), bound) == .lt) return error.KeyOutOfBounds; // T3
                if (hi) |bound| if (std.mem.order(u8, page.key(n - 1), bound) != .lt) return error.KeyOutOfBounds;
            }

            if (page.kind() == kind_leaf) {
                if (n == 0 and id != w.tree.root) return error.EmptyPage; // T7
                if (w.leaf_depth == null) w.leaf_depth = depth;
                if (w.leaf_depth.? != depth) return error.UnevenDepth; // T4
                w.keys += n;
                try w.leaves.append(scratch, .{ .id = id, .next = link(page) });
                return;
            }
            if (page.kind() != kind_interior) return error.BadPage;
            if (n == 0) return error.EmptyPage; // T7

            // Recurse without a pin (the pool may be tiny): work on a copy.
            const copy = try scratch.create(Page);
            copy.* = buf.*;
            pool.unpin(id, false);
            pinned = false;
            page = SlottedPage.open(copy);
            for (0..n + 1) |i| {
                const child_lo = if (i == 0) lo else page.key(i - 1);
                const child_hi = if (i == n) hi else page.key(i);
                try w.visit(childAt(page, i), child_lo, child_hi, depth + 1);
            }
        }
    };

    // ---- inspection -------------------------------------------------------------

    /// Number of levels: 1 for a root that is a leaf.
    pub fn height(self: *DiskBTree) Error!u32 {
        var levels: u32 = 1;
        var id = self.root;
        while (true) : (levels += 1) {
            const page = try self.pinNode(id);
            const child = if (page.kind() == kind_leaf) null else childAt(page, 0);
            self.pool.unpin(id, false);
            id = child orelse return levels;
        }
    }

    /// Print the tree, one page per line, children indented under their
    /// parent. Keys are printed as text and values as their length, so this
    /// is meant for trees with printable keys.
    pub fn dump(self: *DiskBTree, w: *Io.Writer) (Error || Io.Writer.Error)!void {
        defer _ = self.arena.reset(.retain_capacity);
        try self.dumpPage(w, self.root, 0);
    }

    fn dumpPage(self: *DiskBTree, w: *Io.Writer, id: PageId, depth: usize) (Error || Io.Writer.Error)!void {
        const page = try self.pinNode(id);
        var pinned = true;
        defer if (pinned) self.pool.unpin(id, false);
        const n = page.count();
        const used = page_capacity - page.freeBytes();
        try w.splatByteAll(' ', 2 * depth);
        if (page.kind() == kind_leaf) {
            try w.print("page {d}  leaf      {d} keys  {d}/{d} bytes  next ", .{ id, n, used, page_capacity });
            if (link(page) == invalid_page_id) try w.writeAll("-") else try w.print("{d}", .{link(page)});
            try w.writeAll("  |");
            for (0..n) |i| try w.print(" {s}:{d}", .{ page.key(i), page.value(i).len });
            try w.writeAll("\n");
            return;
        }
        try w.print("page {d}  interior  {d} keys  {d}/{d} bytes  |", .{ id, n, used, page_capacity });
        const children = try self.arena.allocator().alloc(PageId, n + 1);
        for (children, 0..) |*child, i| {
            child.* = childAt(page, i);
            if (i < n) try w.print(" ({d}) {s}", .{ child.*, page.key(i) }) else try w.print(" ({d})\n", .{child.*});
        }
        self.pool.unpin(id, false);
        pinned = false;
        for (children) |child| try self.dumpPage(w, child, depth + 1);
    }
};
