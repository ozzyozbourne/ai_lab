// Copied from chapters/12-disk-backed-bplus-tree/zig/src/disk_btree.zig and extended:
// overflow chains, `delete` with free-at-empty, the on-disk free list, a
// wider `validate`. The split code (pushRootDown, splitLeaf, insertSeparator,
// splitInterior, splitPoint) is chapter 12's, with `pool.newPage()` replaced
// by `allocPage()` and an order check added to `insertSeparator`.
//! disk_btree.zig: a B+tree of slotted pages with large values and a free list.
//!
//! Layers (each one only talks to the one below):
//!
//!   DiskBTree      this file: keys, splits, overflow chains, the free list
//!   SlottedPage    base_slotted_page.zig: cells inside one 4096-byte page
//!   BufferPool     base_buffer_pool.zig: page id -> pinned frame in memory
//!   Pager          base_pager.zig: page id -> byte offset in the storage
//!   Storage        base_storage.zig: a file, or memory with fault injection
//!
//! Every page of the file has exactly ONE of these roles
//! =====================================================
//!
//!   metapage   page 0 (see `Meta`)
//!   tree page  a leaf or an interior page reachable from the root (page 1)
//!   overflow   one link of the chain that holds the tail of ONE large value
//!   trunk      a page of the free list: an array of free page ids
//!   free       a page listed in a trunk; its content means nothing
//!
//! Byte 7 of every formatted page says what it was last formatted as (the
//! slotted page's `kind` byte; overflow and trunk pages keep theirs at the
//! same offset), and the last 4 bytes of every page stay zero, reserved for
//! the checksum of chapters 21 and 22.
//!
//!   tree page (kind 1 = leaf, 2 = interior): a slotted page, as in chapter 12
//!     user area bytes 0..4: the link (leaf: right sibling; interior:
//!     rightmost child). Interior cell i is (K_i -> child with keys < K_i).
//!
//!   leaf cell: key -> value field
//!       0   u32  total length of the value, P
//!       4   the first localLen(P) bytes of the value
//!       ..  u32  first overflow page    (only if P > max_local)
//!
//!   overflow page (kind 3)
//!       0   u32  next overflow page, invalid_page_id = last
//!       7   u8   kind
//!       8   payload, `overflow_payload` = 4084 bytes; every page of a chain
//!           is full except possibly the last
//!
//!   trunk page (kind 4)
//!       0   u32  next trunk page, invalid_page_id = last
//!       4   u16  n, the number of ids that follow
//!       7   u8   kind
//!       8   n * u32 free page ids, at most `trunk_capacity` = 1021
//!
//! Invariants (checked by `validate`)
//!   T1  every tree page is a well-formed slotted page of a known kind
//!   T2  keys are strictly ascending inside a page
//!   T3  every key of a subtree lies inside the bounds its ancestors'
//!       separators give it: lower bound inclusive, upper bound exclusive
//!   T4  all leaves are at the same depth, and there are at most
//!       `max_height` levels
//!   T5  following the links from the leftmost leaf visits every leaf once,
//!       in key order, and ends with invalid_page_id
//!   T6  every page has exactly one role: none is unreachable, none is
//!       reached twice, none has two roles
//!   T7  no empty page: only the root may be a leaf without cells, and the
//!       root is never an interior page without keys (a non-root interior
//!       page may have no key, but it always has one child)
//!   T8  the number of keys in the leaves equals `key_count`
//!   T9  every value field is well formed, and its overflow chain has
//!       exactly overflowPages(P) pages of kind 3
//!   T10 the free list is a chain of trunk pages listing `free_count` pages
//!
//! Two ordering rules keep a FAILED operation from doing worse than leaking
//! pages: a pointer is written only after the page it points to is complete
//! (the chain before the leaf cell), and a page is freed only after the last
//! pointer to it is gone (the parent before the child, the leaf cell before
//! the chain). They do nothing for a CRASH: see the end of this comment.
//!
//! Pins. No pin outlives the function that took it, and at most TWO pages are
//! pinned at any moment, so a 2-frame pool still works: the two halves of a
//! split, a leaf and one page of a chain, two consecutive pages of a chain
//! being written, the root and its only child. The free list never needs a
//! third pin: a trunk is unpinned before the page it handed out is fetched.
//!
//! The file is untrusted input. Every count, length and page id that comes
//! from a page is checked before it is used as an index or followed, and
//! every walk has a bound, so a damaged file gives `Corrupt` (or a wrong
//! answer that `validate` explains), never a crash or an endless loop:
//!
//!   tree page     checked as a whole (`nodeIsSound`) the first time this
//!                 handle pins it; see `pinNode`
//!   page id       must lie inside the file and must not be page 0
//!   descent       at most `max_height` levels
//!   leaf chain    a scan follows at most as many links as the file has pages
//!   value field   `parseField`; a chain has exactly overflowPages(P) pages
//!   trunk         kind byte, count <= `trunk_capacity`, the id handed out
//!   metapage      `open`; the two counters before they are changed
//!
//! Memory. Nodes live in the pool's frame slab. Each operation gets scratch
//! memory from one ArenaAllocator that is reset when the operation returns.
//! A value that is read is assembled in memory of the CALLER's choosing
//! (`get` takes an allocator); the range iterator uses a buffer-first chain:
//! its own inline buffer for values that were stored in the leaf, the heap
//! only for values that had an overflow chain.
//!
//! NOT crash-safe, and not error-atomic. An operation changes several pages
//! and the file receives them one at a time. If `put` or `delete` fails after
//! its first page change (I/O error, out of memory), the handle marks itself
//! poisoned and refuses further work. Worse than in chapter 12: a freed page
//! is REUSED AT ONCE, so after a crash an old leaf cell on disk can point at
//! pages that already hold another value. Chapter 22 fixes this with a log.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const pager_mod = @import("base_pager.zig");
const pool_mod = @import("base_buffer_pool.zig");
const slotted = @import("base_slotted_page.zig");
const SlottedPage = slotted.SlottedPage;
const BufferPool = pool_mod.BufferPool;
const PagePtr = pool_mod.PagePtr;

pub const Page = pager_mod.Page;
pub const PageId = pager_mod.PageId;
pub const page_size = pager_mod.page_size;
pub const invalid_page_id = pager_mod.invalid_page_id;

pub const meta_page_id: PageId = 0;
pub const magic = "BTREE12\x00";
/// 2: the metapage has a free-list head and leaf values carry a length.
/// (Chapter 12 wrote version 1 and refuses this file; this code refuses its.)
pub const format_version: u32 = 2;
/// Bytes at the end of every page that the tree never touches.
pub const reserved_tail = 4;

pub const kind_leaf: u8 = 1;
pub const kind_interior: u8 = 2;
pub const kind_overflow: u8 = 3;
pub const kind_trunk: u8 = 4;
/// Where every page keeps its kind (the slotted page's `kind` byte).
const off_kind = 7;
/// Overflow and trunk pages: 4 bytes of link, 3 spare, the kind byte.
const plain_header = 8;

/// Bytes an empty tree page offers to cells and their slots.
pub const page_capacity = page_size - reserved_tail - slotted.header_size;
pub const max_key_len = 256;
/// Sixteen pages. The limit is arbitrary now: no value has to fit in a page.
pub const max_value_len = 65536;
/// No tree has more levels than this, so a descent that goes deeper is in a
/// damaged file (a child pointer that leads back up). Why 32 is out of
/// reach: a level is added only when the root is full, and after a split a
/// page needs at least 7 more separators to fill up again, each of them from
/// a split one level down. A tree with L levels has therefore seen more than
/// 7^(L-2) leaf splits.
pub const max_height = 32;

/// What a cell costs its page: the cell itself plus its slot.
pub fn cellCost(key_len: usize, value_len: usize) usize {
    return slotted.cellSize(key_len, value_len) + slotted.slot_size;
}

/// A value field: 4 bytes of total length in front, and, if the value
/// spilled, 4 bytes of page id behind the local part.
const field_len_size = 4;
const field_ptr_size = @sizeOf(PageId);

/// X, the most value bytes a leaf cell keeps. The split argument of chapter
/// 12 (see `splitPoint`) needs every cell to cost at most a third of a page,
/// and that fixes X: take a third of the capacity and subtract everything
/// else a cell with the longest key costs.
///
///   X = 4076/3 - slot 2 - cell header 4 - key 256 - length 4 - page id 4
///     = 1358 - 270 = 1088
pub const max_local = page_capacity / 3 - slotted.slot_size - slotted.cell_header_size - max_key_len - field_len_size - field_ptr_size;
/// M, the fewest value bytes a spilled value keeps in its leaf: half of X,
/// the proportion SQLite uses for its index pages (32/255 against 64/255).
pub const min_local = max_local / 2;
/// Value bytes on one overflow page.
pub const overflow_payload = page_size - reserved_tail - plain_header;
/// Free page ids on one trunk page.
pub const trunk_capacity = (page_size - reserved_tail - plain_header) / @sizeOf(PageId);
/// The longest value field: X local bytes between the length and the id.
pub const max_field_len = field_len_size + max_local + field_ptr_size;

comptime {
    // The one-third rule of chapter 12, now for the LOCAL part of a cell.
    assert(3 * cellCost(max_key_len, max_field_len) <= page_capacity);
    assert(max_local == 1088 and min_local == 544 and overflow_payload == 4084 and trunk_capacity == 1021);
    assert(slotted.user_area_size >= @sizeOf(PageId));
}

/// How many bytes of a value of `total` bytes stay in the leaf cell. This is
/// SQLite's rule (see the README for the source lines):
///
///   P <= X                     everything is local
///   K = M + (P - M) mod 4084   what is left over after filling whole
///                              overflow pages, counted from M
///   K <= X                     keep K: every overflow page is then FULL
///   otherwise                  keep M: the last overflow page is part full
///
/// So the leaf absorbs a remainder of up to X - M = 544 bytes instead of
/// spending a page on it, and otherwise keeps as little as allowed, which
/// leaves room for more cells per leaf.
///
///   P = 1088 -> 1088 local, no chain
///   P = 1089 -> K = 1089 > X: 544 local + 545 on one page
///   P = 5000 -> K = 544 + 4456 mod 4084 = 916: 916 local + one full page
///   P = 9000 -> K = 544 + 8456 mod 4084 = 832: 832 local + two full pages
pub fn localLen(total: usize) usize {
    if (total <= max_local) return total;
    const k = min_local + (total - min_local) % overflow_payload;
    return if (k <= max_local) k else min_local;
}

/// Length of the overflow chain of a value of `total` bytes, in pages.
pub fn overflowPages(total: usize) usize {
    return std.math.divCeil(usize, total - localLen(total), overflow_payload) catch unreachable;
}

/// A decoded value field. `local` points into the field.
pub const ValueRef = struct {
    total: usize,
    local: []const u8,
    /// First page of the overflow chain, or invalid_page_id.
    first: PageId,
};

/// Decode a leaf cell's value field. Safe on any bytes.
pub fn parseField(field: []const u8) error{Corrupt}!ValueRef {
    if (field.len < field_len_size) return error.Corrupt;
    const total: usize = std.mem.readInt(u32, field[0..4], .little);
    if (total > max_value_len) return error.Corrupt;
    const local = localLen(total);
    const spilled = total > max_local;
    if (field.len != field_len_size + local + @as(usize, if (spilled) field_ptr_size else 0)) return error.Corrupt;
    const first = if (spilled) std.mem.readInt(u32, field[field.len - 4 ..][0..4], .little) else invalid_page_id;
    if (spilled and first == invalid_page_id) return error.Corrupt;
    return .{ .total = total, .local = field[field_len_size..][0..local], .first = first };
}

/// The metapage, page 0. Little-endian, like every integer on disk.
///
///    0  [8]  magic "BTREE12\0"
///    8  u32  format version (2)
///   12  u32  page size (4096)
///   16  u32  root page id (always 1)
///   20  u32  page count        }
///   24  u64  key count         } as of the last `flush`; between flushes
///   32  u32  free-list head    } the file can be ahead of them
///   36  u32  free page count   }
///   ..       zero; the last 4 bytes are reserved like on every other page
pub const Meta = struct {
    root: PageId,
    page_count: u32,
    key_count: u64,
    /// First trunk page of the free list, or invalid_page_id.
    free_head: PageId,
    /// Trunk pages plus the pages they list.
    free_count: u32,

    fn encode(self: Meta, buf: *Page) void {
        @memset(buf, 0);
        @memcpy(buf[0..8], magic);
        std.mem.writeInt(u32, buf[8..12], format_version, .little);
        std.mem.writeInt(u32, buf[12..16], page_size, .little);
        std.mem.writeInt(u32, buf[16..20], self.root, .little);
        std.mem.writeInt(u32, buf[20..24], self.page_count, .little);
        std.mem.writeInt(u64, buf[24..32], self.key_count, .little);
        std.mem.writeInt(u32, buf[32..36], self.free_head, .little);
        std.mem.writeInt(u32, buf[36..40], self.free_count, .little);
    }

    fn decode(buf: *const Page) error{ BadMagic, UnsupportedVersion }!Meta {
        if (!std.mem.eql(u8, buf[0..8], magic)) return error.BadMagic;
        if (std.mem.readInt(u32, buf[8..12], .little) != format_version) return error.UnsupportedVersion;
        if (std.mem.readInt(u32, buf[12..16], .little) != page_size) return error.UnsupportedVersion;
        return .{
            .root = std.mem.readInt(u32, buf[16..20], .little),
            .page_count = std.mem.readInt(u32, buf[20..24], .little),
            .key_count = std.mem.readInt(u64, buf[24..32], .little),
            .free_head = std.mem.readInt(u32, buf[32..36], .little),
            .free_count = std.mem.readInt(u32, buf[36..40], .little),
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

/// Is this page a tree page that the code below can use without looking
/// twice? Safe on any bytes. The slotted page's own `validate` covers
/// everything inside the page (slots, cell bounds, the free blocks, key
/// order); the rest is what the TREE assumes about a cell: a key of at most
/// `max_key_len` bytes, in a leaf a value field that can be one, in an
/// interior page a 4-byte child id. Without those the one-third rule behind
/// `splitPoint` would not hold and `childAt` would read past a cell.
pub fn nodeIsSound(page: SlottedPage) bool {
    const leaf = page.kind() == kind_leaf;
    if (!leaf and page.kind() != kind_interior) return false;
    if (page.reservedSize() != reserved_tail) return false;
    page.validate() catch return false;
    for (0..page.count()) |i| {
        if (page.key(i).len > max_key_len) return false;
        const len = page.value(i).len;
        if (if (leaf) len > max_field_len else len != @sizeOf(PageId)) return false;
    }
    return true;
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

// ---- overflow and trunk pages: a link, a kind byte, a payload -----------------

fn plainNext(page: *const Page) PageId {
    return std.mem.readInt(u32, page[0..4], .little);
}

/// `page` must be zero-filled, as `allocPage` returns it.
fn formatPlain(page: *Page, kind: u8, next: PageId) void {
    std.mem.writeInt(u32, page[0..4], next, .little);
    page[off_kind] = kind;
}

fn trunkCount(page: *const Page) usize {
    return std.mem.readInt(u16, page[4..6], .little);
}

fn trunkEntry(page: *Page, i: usize) *[4]u8 {
    return page[plain_header + 4 * i ..][0..4];
}

/// What a page is used for. `validate` assigns one to every page of the file.
pub const Role = enum(u8) {
    unseen,
    meta,
    interior,
    leaf,
    overflow,
    trunk,
    free,

    /// One letter per role, for page maps.
    pub fn letter(self: Role) u8 {
        return "?MILOTF"[@backingInt(self)];
    }

    fn family(self: Role) u8 {
        return switch (self) {
            .interior, .leaf => 1,
            .trunk, .free => 2,
            else => @backingInt(self) + 3,
        };
    }
};

pub const DiskBTree = struct {
    /// Borrowed: the caller owns the pool (and the pager under it).
    pool: *BufferPool,
    /// Backs the arena, and the range iterator's large values.
    gpa: Allocator,
    /// Scratch memory of the operation in progress; reset when it returns.
    arena: std.heap.ArenaAllocator,
    root: PageId,
    key_count: u64,
    /// The free list: first trunk page, and how many pages it holds in all.
    free_head: PageId,
    free_count: u32,
    /// One flag per page the file had when it was opened: true once the page
    /// has passed `nodeIsSound`. Pages added later are this handle's work.
    checked: []bool,
    /// True once the operation in progress has changed a page.
    changed: bool = false,
    /// Set when a `put` or `delete` failed after its first page change.
    poisoned: bool = false,
    stats: Stats = .{},

    pub const Stats = struct {
        leaf_splits: u64 = 0,
        interior_splits: u64 = 0,
        /// Times the root's content moved down one level (the height grew).
        root_splits: u64 = 0,
        /// Times the root's only child moved up into it (the height shrank).
        root_collapses: u64 = 0,
        /// Leaves and interior pages removed from the tree by `delete`.
        tree_pages_freed: u64 = 0,
        /// How many of those were interior pages.
        interior_pages_freed: u64 = 0,
        /// Pages handed to the free list (tree pages and overflow pages).
        pages_freed: u64 = 0,
        /// Allocations served from the free list instead of growing the file.
        pages_reused: u64 = 0,
        overflow_pages_written: u64 = 0,
    };

    pub const Error = BufferPool.Error || Allocator.Error || error{
        /// `create` on a storage that already has pages.
        NotEmpty,
        /// `open`: page 0 is not a metapage of this format.
        BadMagic,
        UnsupportedVersion,
        /// A page is not what the tree expects there (wrong kind, a link
        /// that leaves the file, a chain of the wrong length).
        Corrupt,
        KeyTooLarge,
        ValueTooLarge,
        /// An earlier `put` or `delete` failed half-way.
        TreePoisoned,
    };

    pub const ValidateError = error{
        BadPage, // T1, T2
        KeyOutOfBounds, // T3
        UnevenDepth, // T4
        LeafChainBroken, // T5
        PageReachedTwice, // T6: twice in the same role
        PageInTwoRoles, // T6: for example free and in the tree
        UnreachablePage, // T6
        EmptyPage, // T7
        KeyCountMismatch, // T8
        BadCell, // T9
        OverflowChainBroken, // T9
        FreeListBroken, // T10
    };

    const PathEntry = struct { id: PageId, index: usize };
    /// What a split hands to the level above: `left` kept the keys below
    /// `sep`, the new page `right` got the keys from `sep` on.
    const Carry = struct { sep: []const u8, left: PageId, right: PageId };
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

        var tree: DiskBTree = .{ .pool = pool, .gpa = gpa, .arena = .init(gpa), .root = root.id, .key_count = 0, .free_head = invalid_page_id, .free_count = 0, .checked = &.{} };
        errdefer tree.deinit();
        try tree.flush();
        return tree;
    }

    /// Open an existing tree. Only the metapage is read here, and every
    /// number in it is checked against the size of the file.
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
        const no_list = meta.free_head == invalid_page_id;
        if (no_list != (meta.free_count == 0) or meta.free_count >= pages) return error.Corrupt;
        if (!no_list and (meta.free_head == meta_page_id or meta.free_head >= pages)) return error.Corrupt;
        const checked = try gpa.alloc(bool, pages);
        @memset(checked, false);
        return .{ .pool = pool, .gpa = gpa, .arena = .init(gpa), .root = meta.root, .key_count = meta.key_count, .free_head = meta.free_head, .free_count = meta.free_count, .checked = checked };
    }

    /// Free the scratch arena. Does not flush: see `close`.
    pub fn deinit(self: *DiskBTree) void {
        self.arena.deinit();
        self.gpa.free(self.checked);
        self.* = undefined;
    }

    /// Bring the file up to date: write the metapage, write every dirty
    /// page, sync. The pages go out one after the other, in frame order, so
    /// a crash in the middle leaves a mix of old and new pages.
    pub fn flush(self: *DiskBTree) Error!void {
        if (self.poisoned) return error.TreePoisoned;
        const buf = try self.pool.fetchPage(meta_page_id);
        const meta: Meta = .{ .root = self.root, .page_count = self.pool.pager.pageCount(), .key_count = self.key_count, .free_head = self.free_head, .free_count = self.free_count };
        meta.encode(buf);
        self.pool.unpin(meta_page_id, true);
        try self.pool.flushAll();
    }

    /// `flush`, then `deinit` (also when the flush fails).
    pub fn close(self: *DiskBTree) Error!void {
        defer self.deinit();
        try self.flush();
    }

    // ---- pinning pages by role ----------------------------------------------

    /// Fetch and pin page `id` as a tree node. A page that is not a node of
    /// this tree (zeroes, an overflow page, a trunk, damaged bytes) is
    /// reported as `Corrupt` and not pinned.
    ///
    /// The slotted page trusts its bytes, so a page from the file must pass
    /// `nodeIsSound` before anything searches it. That check reads the whole
    /// page; it runs ONCE per page and handle, the first time the page is
    /// pinned as a node. After that the page only changes through this
    /// code, in memory or on its way to the file and back. (A checksum,
    /// chapter 21, is checked at the same moment for the same reason.)
    fn pinNode(self: *DiskBTree, id: PageId) Error!SlottedPage {
        if (id == meta_page_id or id >= self.pool.pager.pageCount()) return error.Corrupt;
        const page = SlottedPage.open(try self.pool.fetchPage(id));
        const known = page.kind() == kind_leaf or page.kind() == kind_interior;
        const unchecked = id < self.checked.len and !self.checked[id];
        if (!known or page.reservedSize() != reserved_tail or (unchecked and !nodeIsSound(page))) {
            self.pool.unpin(id, false);
            return error.Corrupt;
        }
        if (unchecked) self.checked[id] = true;
        return page;
    }

    /// True if somebody holds a pin on page `id` right now.
    fn isPinned(self: *const DiskBTree, id: PageId) bool {
        const frame = self.pool.frameOf(id) orelse return false;
        return self.pool.frames[frame].pin_count > 0;
    }

    /// Fetch and pin page `id` as an overflow or trunk page.
    fn pinPlain(self: *DiskBTree, id: PageId, kind: u8) Error!PagePtr {
        if (id == meta_page_id or id >= self.pool.pager.pageCount()) return error.Corrupt;
        const page = try self.pool.fetchPage(id);
        if (page[off_kind] != kind) {
            self.pool.unpin(id, false);
            return error.Corrupt;
        }
        return page;
    }

    // ---- the free list ------------------------------------------------------
    //
    // A linked list of trunk pages, each an array of free page ids: SQLite's
    // design. Freeing a page usually costs one write to a page that is
    // probably cached (the first trunk), and the freed page itself is not
    // touched. A plain linked list through the free pages would have to
    // write every page it frees and read every page it reuses.

    /// A pinned, zero-filled page that belongs to nobody: taken from the
    /// free list if it has one, else the file grows by a page. The caller
    /// formats it and unpins it dirty.
    fn allocPage(self: *DiskBTree) Error!BufferPool.NewPage {
        if (self.free_head == invalid_page_id) {
            const page = try self.pool.newPage();
            self.changed = true;
            return page;
        }
        const trunk_id = self.free_head;
        const trunk = try self.pinPlain(trunk_id, kind_trunk);
        // The count comes from the file: check it BEFORE it is used as an
        // index. (And a list that still has a trunk holds at least one page.)
        const n = trunkCount(trunk);
        if (n > trunk_capacity or self.free_count == 0) {
            self.pool.unpin(trunk_id, false);
            return error.Corrupt;
        }
        if (n == 0) {
            // A trunk that lists nothing is itself the next free page.
            self.free_head = plainNext(trunk);
            @memset(trunk, 0);
            self.took();
            return .{ .id = trunk_id, .page = trunk };
        }
        // Take the LAST id: no other entry moves. The id comes from the file
        // too. A free page is inside the file and nobody has it pinned: a
        // pinned one is this trunk or a page of the operation in progress.
        const id = std.mem.readInt(u32, trunkEntry(trunk, n - 1), .little);
        if (id == meta_page_id or id >= self.pool.pager.pageCount() or self.isPinned(id)) {
            self.pool.unpin(trunk_id, false);
            return error.Corrupt;
        }
        @memset(trunkEntry(trunk, n - 1), 0);
        std.mem.writeInt(u16, trunk[4..6], @intCast(n - 1), .little);
        // Unpin the trunk BEFORE fetching the page: the caller may hold a
        // pin of its own, and two is all a small pool has. The price: if
        // the fetch fails, the id has already left the list (a leaked page;
        // `changed` makes the caller poison the handle).
        self.pool.unpin(trunk_id, true);
        self.took();
        // The pool can only hand out a page by reading it, although the old
        // content is about to be erased (exercise 2).
        const page = try self.pool.fetchPage(id);
        @memset(page, 0);
        return .{ .id = id, .page = page };
    }

    fn took(self: *DiskBTree) void {
        self.free_count -= 1;
        self.stats.pages_reused += 1;
        self.changed = true;
    }

    /// Put page `id` on the free list. Nothing may point to it any more.
    fn freePage(self: *DiskBTree, id: PageId) Error!void {
        // Whatever happens below, the page has already left the tree.
        self.changed = true;
        // A list cannot hold more pages than the file has. (This also ends
        // every loop that frees pages of a damaged file again and again.)
        if (self.free_count >= self.pool.pager.pageCount()) return error.Corrupt;
        if (self.free_head != invalid_page_id) {
            const trunk_id = self.free_head;
            const trunk = try self.pinPlain(trunk_id, kind_trunk);
            const n = trunkCount(trunk);
            if (n < trunk_capacity) {
                // The usual case: one more id in the first trunk. Page `id`
                // is not read and not written; its old bytes stay.
                std.mem.writeInt(u32, trunkEntry(trunk, n), id, .little);
                std.mem.writeInt(u16, trunk[4..6], @intCast(n + 1), .little);
                self.pool.unpin(trunk_id, true);
                self.gave();
                return;
            }
            self.pool.unpin(trunk_id, false);
        }
        // No trunk, or a full one: the freed page becomes the new first
        // trunk, pointing at the old one.
        const page = try self.pool.fetchPage(id);
        @memset(page, 0);
        formatPlain(page, kind_trunk, self.free_head);
        self.pool.unpin(id, true);
        self.free_head = id;
        self.gave();
    }

    fn gave(self: *DiskBTree) void {
        self.free_count += 1;
        self.stats.pages_freed += 1;
    }

    // ---- overflow chains ----------------------------------------------------

    /// Encode `value` as a leaf cell's value field in `buf`. If it is too
    /// large for the leaf, its tail is written to a new overflow chain
    /// first: the field must never point at pages that do not exist yet.
    fn writeValue(self: *DiskBTree, value: []const u8, buf: *[max_field_len]u8) Error![]const u8 {
        const local = localLen(value.len);
        std.mem.writeInt(u32, buf[0..4], @intCast(value.len), .little);
        @memcpy(buf[field_len_size..][0..local], value[0..local]);
        if (local == value.len) return buf[0 .. field_len_size + local];
        const first = try self.writeChain(value[local..]);
        std.mem.writeInt(u32, buf[field_len_size + local ..][0..4], first, .little);
        return buf[0 .. field_len_size + local + field_ptr_size];
    }

    /// Write `tail` to a chain of new overflow pages, front to back, and
    /// return the first page. The previous page stays pinned while the next
    /// one is allocated, because only then is the id for its link known.
    fn writeChain(self: *DiskBTree, tail: []const u8) Error!PageId {
        var first: PageId = invalid_page_id;
        var prev: ?BufferPool.NewPage = null;
        errdefer if (prev) |p| self.pool.unpin(p.id, true);
        var rest = tail;
        while (rest.len > 0) {
            const page = try self.allocPage();
            formatPlain(page.page, kind_overflow, invalid_page_id);
            const n = @min(rest.len, overflow_payload);
            @memcpy(page.page[plain_header..][0..n], rest[0..n]);
            rest = rest[n..];
            if (prev) |p| {
                std.mem.writeInt(u32, p.page[0..4], page.id, .little);
                self.pool.unpin(p.id, true);
            } else first = page.id;
            prev = page;
            self.stats.overflow_pages_written += 1;
        }
        if (prev) |p| self.pool.unpin(p.id, true);
        return first;
    }

    /// Fill `out` from the chain that starts at `first`: the part of a value
    /// that is not in its leaf. One page pinned at a time.
    fn readChain(self: *DiskBTree, first: PageId, out: []u8) Error!void {
        var id = first;
        var rest = out;
        while (rest.len > 0) {
            const pinned = id;
            const page = try self.pinPlain(pinned, kind_overflow);
            defer self.pool.unpin(pinned, false);
            const n = @min(rest.len, overflow_payload);
            @memcpy(rest[0..n], page[plain_header..][0..n]);
            rest = rest[n..];
            id = plainNext(page);
        }
        // The chain must end exactly where the stored length says.
        if (id != invalid_page_id) return error.Corrupt;
    }

    /// Give the `pages` pages of the chain starting at `first` to the free
    /// list. Each page is read for its link before it is freed.
    fn freeChain(self: *DiskBTree, first: PageId, pages: usize) Error!void {
        var id = first;
        for (0..pages) |_| {
            const page = try self.pinPlain(id, kind_overflow);
            const next = plainNext(page);
            self.pool.unpin(id, false);
            try self.freePage(id);
            id = next;
        }
        if (id != invalid_page_id) return error.Corrupt;
    }

    /// A value being assembled: `buf` has room for all of it and holds the
    /// local part; the chain from `first` fills `buf[filled..]`.
    const Pending = struct { buf: []u8, filled: usize, first: PageId };

    /// Allocate room for the whole value behind `field` and copy the local
    /// part. The caller unpins the leaf, then calls `readChain`.
    fn startValue(allocator: Allocator, field: []const u8) Error!Pending {
        const ref = try parseField(field);
        const buf = try allocator.alloc(u8, ref.total);
        @memcpy(buf[0..ref.local.len], ref.local);
        return .{ .buf = buf, .filled = ref.local.len, .first = ref.first };
    }

    // ---- get ----------------------------------------------------------------

    /// The value stored under `key`, assembled in memory from `allocator`
    /// (the caller frees it), or null. One allocation of exactly the value's
    /// length; pass a `std.heap.BufferFirstAllocator` to keep small values
    /// on the stack (see demo.zig, part 4).
    pub fn get(self: *DiskBTree, allocator: Allocator, key: []const u8) Error!?[]u8 {
        if (self.poisoned) return error.TreePoisoned;
        const leaf_id = try self.findLeaf(key, null);
        const pending = blk: {
            const leaf = try self.pinNode(leaf_id);
            defer self.pool.unpin(leaf_id, false);
            break :blk try startValue(allocator, leaf.get(key) orelse return null);
        };
        errdefer allocator.free(pending.buf);
        try self.readChain(pending.first, pending.buf[pending.filled..]);
        return pending.buf;
    }

    /// Walk from the root to the leaf that owns `key`, one pin at a time: a
    /// parent is unpinned before its child is fetched, which is fine without
    /// concurrency (chapter 19 is about when it is not). If `path` is given,
    /// the interior pages passed and the child index taken in each are
    /// appended to it. Returns the leaf's page id, not pinned.
    fn findLeaf(self: *DiskBTree, key: []const u8, path: ?*std.ArrayList(PathEntry)) Error!PageId {
        var id = self.root;
        for (0..max_height) |_| {
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
        // Deeper than any tree: the child pointers lead in a circle.
        return error.Corrupt;
    }

    // ---- put ----------------------------------------------------------------

    /// Insert `key`, or replace its value if it is already there.
    pub fn put(self: *DiskBTree, key: []const u8, value: []const u8) Error!void {
        if (self.poisoned) return error.TreePoisoned;
        if (key.len > max_key_len) return error.KeyTooLarge;
        if (value.len > max_value_len) return error.ValueTooLarge;
        defer _ = self.arena.reset(.retain_capacity);
        // The steps below are each all-or-nothing, but not together. Once
        // one has changed a page, a failure in a later one leaves pages
        // leaked or the tree half-split.
        self.changed = false;
        errdefer if (self.changed) {
            self.poisoned = true;
        };

        var path: std.ArrayList(PathEntry) = .empty;
        const leaf_id = try self.findLeaf(key, &path);
        // 1. What is stored under the key now? An old chain is freed at the
        //    very end, when no cell points at it any more.
        var old_first: PageId = invalid_page_id;
        var old_pages: usize = 0;
        var existed = false;
        {
            const leaf = try self.pinNode(leaf_id);
            defer self.pool.unpin(leaf_id, false);
            if (leaf.get(key)) |field| {
                const old = try parseField(field);
                existed = true;
                old_first = old.first;
                old_pages = overflowPages(old.total);
            }
        }
        // (the metapage's counter is a number from the file like any other)
        if (!existed and self.key_count == std.math.maxInt(u64)) return error.Corrupt;
        // 2. The new value field; a large value gets its chain here.
        var field_buf: [max_field_len]u8 = undefined;
        const field = try self.writeValue(value, &field_buf);
        // 3. The leaf cell. To the tree the field is just a value of at
        //    most 1096 bytes, so the split code of chapter 12 is unchanged.
        const leaf = try self.pinNode(leaf_id);
        if (leaf.put(key, field)) |_| {
            self.pool.unpin(leaf_id, true);
            self.changed = true;
        } else |err| switch (err) {
            error.CellTooLarge => unreachable, // excluded by the length checks
            error.PageFull => {
                self.pool.unpin(leaf_id, false);
                try self.splitAndInsert(&path, leaf_id, key, field);
            },
        }
        // 4. The old chain, if the old value had one.
        try self.freeChain(old_first, old_pages);
        if (!existed) self.key_count += 1;
    }

    /// The leaf `leaf_id` has no room for (key, value). Split it, then hand
    /// the separator to the parent; if the parent has no room either, split
    /// that too, and so on up the remembered path. Splits therefore run
    /// bottom-up: only now, at the leaf, do we know that a split is needed
    /// and how many bytes the parent must take.
    fn splitAndInsert(self: *DiskBTree, path: *std.ArrayList(PathEntry), leaf_id: PageId, key: []const u8, value: []const u8) Error!void {
        const scratch = self.arena.allocator();
        var id = leaf_id;
        if (path.items.len == 0) {
            // The leaf is the root. The root never splits: its content
            // moves down first, and the page below it splits.
            id = try self.pushRootDown();
            try path.append(scratch, .{ .id = self.root, .index = 0 });
        }
        var carry = try self.splitLeaf(id, key, value);

        while (true) {
            var parent = path.pop().?;
            if (try self.insertSeparator(parent, carry)) return;
            if (path.items.len == 0) {
                // The full parent is the root: same move, one level up. The
                // child index stays valid because the cells moved unchanged.
                parent.id = try self.pushRootDown();
                try path.append(scratch, .{ .id = self.root, .index = 0 });
            }
            carry = try self.splitInterior(parent, carry);
        }
    }

    /// Grow the tree by one level WITHOUT changing the root's page id: copy
    /// the root page into a new page and turn the root into an interior page
    /// with no key and that new page as its only (rightmost) child. Returns
    /// the new page, which the caller then splits like any other page.
    fn pushRootDown(self: *DiskBTree) Error!PageId {
        const root = try self.pool.fetchPage(self.root);
        errdefer self.pool.unpin(self.root, false);
        const child = try self.allocPage();
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
    /// to a new page and is linked in after it.
    fn splitLeaf(self: *DiskBTree, id: PageId, key: []const u8, value: []const u8) Error!Carry {
        const scratch = self.arena.allocator();
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

        const right = try self.allocPage(); // the last step that can fail
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
    fn insertSeparator(self: *DiskBTree, parent: PathEntry, carry: Carry) Error!bool {
        const page = try self.pinNode(parent.id);
        errdefer self.pool.unpin(parent.id, false);
        if (page.kind() != kind_interior or parent.index > page.count()) return error.Corrupt;
        if (childAt(page, parent.index) != carry.left) return error.Corrupt;
        // In a sound tree the separator sorts between its new neighbours
        // (T3). `insertAt` asserts it, and so does the split of this page.
        if (parent.index > 0 and std.mem.order(u8, page.key(parent.index - 1), carry.sep) != .lt) return error.Corrupt;
        if (parent.index < page.count() and std.mem.order(u8, carry.sep, page.key(parent.index)) != .lt) return error.Corrupt;
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
            const old_key = try self.arena.allocator().dupe(u8, page.key(parent.index));
            page.put(old_key, &childBytes(carry.right)) catch unreachable;
        }
        // ...and the new cell (sep -> left) goes in front of it.
        page.insertAt(parent.index, carry.sep, &childBytes(carry.left)) catch unreachable;
        self.pool.unpin(parent.id, true);
        return true;
    }

    /// Split interior page `parent.id` while inserting the separator of
    /// `carry` at `parent.index`. Unlike in a leaf, the middle key MOVES up:
    /// it separates the two halves and is needed in neither.
    fn splitInterior(self: *DiskBTree, parent: PathEntry, carry: Carry) Error!Carry {
        const scratch = self.arena.allocator();
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

        const right = try self.allocPage(); // the last step that can fail
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

    // ---- delete -------------------------------------------------------------

    /// Remove `key`. Returns false if it was not there.
    ///
    /// "Free at empty": a leaf is given back only when its LAST cell goes.
    /// Pages that are merely less than half full are left alone; nothing is
    /// merged and nothing is borrowed from a sibling (the README says why).
    pub fn delete(self: *DiskBTree, key: []const u8) Error!bool {
        if (self.poisoned) return error.TreePoisoned;
        if (key.len > max_key_len) return false;
        defer _ = self.arena.reset(.retain_capacity);
        self.changed = false;
        errdefer if (self.changed) {
            self.poisoned = true;
        };

        var path: std.ArrayList(PathEntry) = .empty;
        const leaf_id = try self.findLeaf(key, &path);
        const leaf = try self.pinNode(leaf_id);
        const r = leaf.search(key);
        if (!r.found) {
            self.pool.unpin(leaf_id, false);
            return false;
        }
        const old = parseField(leaf.value(r.index)) catch |err| {
            self.pool.unpin(leaf_id, false);
            return err;
        };
        if (self.key_count == 0) {
            // A key in a tree that the metapage says is empty.
            self.pool.unpin(leaf_id, false);
            return error.Corrupt;
        }
        const old_first = old.first;
        const old_pages = overflowPages(old.total);
        const next = link(leaf);
        if (leaf.count() > 1 or path.items.len == 0) {
            // The common case: one page changed. (The root may become an
            // empty leaf; it is the one page that is never freed.)
            leaf.deleteAt(r.index);
            self.pool.unpin(leaf_id, true);
            self.changed = true;
        } else {
            // The leaf's last cell: the whole page leaves the tree. Its
            // bytes are not touched, not even to remove the cell.
            self.pool.unpin(leaf_id, false);
            try self.removeLeaf(path.items, leaf_id, next);
        }
        try self.freeChain(old_first, old_pages);
        self.key_count -= 1;
        return true;
    }

    /// Take the leaf at the end of `path` out of the tree and free it.
    ///
    ///   1. the leaf chain: the left sibling's link skips the leaf
    ///   2. the parent: the pointer to the leaf goes, and one separator with
    ///      it. A parent that had no other child goes too, and so on up; a
    ///      root that loses its only child becomes an empty leaf again
    ///   3. only now are the removed pages freed (nothing points at them)
    ///   4. a root left with a single child takes that child's place
    fn removeLeaf(self: *DiskBTree, path: []const PathEntry, leaf_id: PageId, next: PageId) Error!void {
        const scratch = self.arena.allocator();
        if (try self.leftSibling(path)) |left_id| {
            const left = try self.pinNode(left_id);
            if (left.kind() != kind_leaf or link(left) != leaf_id) {
                self.pool.unpin(left_id, false);
                return error.Corrupt;
            }
            setLink(left, next);
            self.pool.unpin(left_id, true);
            self.changed = true;
        }

        var doomed: std.ArrayList(PageId) = .empty;
        try doomed.append(scratch, leaf_id);
        var level = path.len;
        while (true) {
            level -= 1;
            const entry = path[level];
            const page = try self.pinNode(entry.id);
            const n = page.count();
            if (page.kind() != kind_interior or entry.index > n or childAt(page, entry.index) != doomed.getLast()) {
                self.pool.unpin(entry.id, false);
                return error.Corrupt;
            }
            if (n > 0) {
                // Children C_0 .. C_n with separators K_0 .. K_(n-1); C_i
                // goes. If it has a right neighbour, cell i = (K_i -> C_i)
                // goes and C_(i+1) inherits the keys from K_(i-1) on. The
                // rightmost child has no cell: its left neighbour becomes
                // the rightmost child and cell n-1 goes instead. Either
                // way one separator disappears and no key moves.
                if (entry.index == n) {
                    setLink(page, childAt(page, n - 1));
                    page.deleteAt(n - 1);
                } else page.deleteAt(entry.index);
                self.pool.unpin(entry.id, true);
                self.changed = true;
                break;
            }
            if (level == 0) {
                // The root lost its only child: the tree is empty.
                const root = SlottedPage.initReserved(page.buf, reserved_tail);
                root.setKind(kind_leaf);
                setLink(root, invalid_page_id);
                self.pool.unpin(entry.id, true);
                self.changed = true;
                break;
            }
            // An interior page whose only child goes is empty too.
            self.pool.unpin(entry.id, false);
            try doomed.append(scratch, entry.id);
        }
        for (doomed.items) |id| try self.freePage(id);
        self.stats.tree_pages_freed += doomed.items.len;
        self.stats.interior_pages_freed += doomed.items.len - 1;
        try self.collapseRoot();
    }

    /// The leaf just before the leaf at the end of `path`, or null if that
    /// is the first leaf. Leaves are singly linked (the page header has room
    /// for one id), so the left sibling is found from above: go up to the
    /// nearest ancestor where the path did not take child 0, step one child
    /// to the left, then keep right down to a leaf.
    fn leftSibling(self: *DiskBTree, path: []const PathEntry) Error!?PageId {
        var level = path.len;
        const turn = while (level > 0) {
            level -= 1;
            if (path[level].index > 0) break path[level];
        } else return null;
        var id = blk: {
            const page = try self.pinNode(turn.id);
            defer self.pool.unpin(turn.id, false);
            if (page.kind() != kind_interior or turn.index > page.count()) return error.Corrupt;
            break :blk childAt(page, turn.index - 1);
        };
        for (0..max_height) |_| {
            const page = try self.pinNode(id);
            const is_leaf = page.kind() == kind_leaf;
            const rightmost = link(page);
            self.pool.unpin(id, false);
            if (is_leaf) return id;
            id = rightmost;
        }
        return error.Corrupt;
    }

    /// While the root is an interior page with no key, its single child
    /// holds the whole tree: copy the child into the root page and free the
    /// child. This is `pushRootDown` backwards, and like it keeps the root's
    /// page id. Only the root is collapsed; a single-child page further
    /// down stays (exercise 4).
    fn collapseRoot(self: *DiskBTree) Error!void {
        for (0..max_height) |_| {
            const root = try self.pinNode(self.root);
            if (root.kind() != kind_interior or root.count() != 0) {
                self.pool.unpin(self.root, false);
                return;
            }
            const child_id = link(root);
            if (child_id == self.root) {
                self.pool.unpin(self.root, false);
                return error.Corrupt;
            }
            const child = self.pinNode(child_id) catch |err| {
                self.pool.unpin(self.root, false);
                return err;
            };
            root.buf.* = child.buf.*;
            self.pool.unpin(child_id, false);
            self.pool.unpin(self.root, true);
            self.changed = true;
            try self.freePage(child_id);
            self.stats.tree_pages_freed += 1;
            self.stats.interior_pages_freed += @intFromBool(SlottedPage.open(root.buf).kind() == kind_interior);
            self.stats.root_collapses += 1;
        }
        return error.Corrupt;
    }

    // ---- range --------------------------------------------------------------

    /// Iterate over the entries with lo <= key < hi in key order; `hi` null
    /// means "to the end". `lo` = "" starts at the first key. Call `deinit`
    /// on the iterator when done.
    pub fn range(self: *DiskBTree, lo: []const u8, hi: ?[]const u8) Error!RangeIterator {
        if (self.poisoned) return error.TreePoisoned;
        const leaf_id = try self.findLeaf(lo, null);
        const leaf = try self.pinNode(leaf_id);
        defer self.pool.unpin(leaf_id, false);
        return .{ .tree = self, .leaf = leaf_id, .slot = leaf.search(lo).index, .hi = hi };
    }

    /// A position in the leaf level: (leaf page id, slot). It holds no pin
    /// between calls; each `next` pins the leaf, copies one entry out and
    /// unpins. The tree must not be modified while an iterator is in use.
    ///
    /// Where the value goes. Chapter 12 had a fixed buffer as large as the
    /// largest value. That is 64 KiB now, so the iterator carries a buffer
    /// for the common case only: `inline_len` bytes, enough for any value
    /// that was stored whole in its leaf. `next` puts a BufferFirstAllocator
    /// over it: that buffer first, the tree's general-purpose allocator for
    /// a value that is larger. The iterator lives in its caller's stack
    /// frame, so "buffer first" is "stack first".
    pub const RangeIterator = struct {
        tree: *DiskBTree,
        leaf: PageId,
        slot: usize,
        /// Borrowed from the caller of `range`.
        hi: ?[]const u8,
        /// Sibling links followed so far. A scan that follows more links
        /// than the file has pages is going round in a circle.
        hops: usize = 0,
        /// The current value: a slice of `inline_buf`, or heap memory.
        value: []u8 = &.{},
        key_buf: [max_key_len]u8 = undefined,
        inline_buf: [inline_len]u8 = undefined,

        pub const inline_len = max_local;
        pub const Item = struct { key: []const u8, value: []const u8 };

        /// Free the last value if it came from the heap.
        pub fn deinit(self: *RangeIterator) void {
            var chain: std.heap.BufferFirstAllocator = .init(&self.inline_buf, self.tree.gpa);
            chain.allocator().free(self.value);
            self.* = undefined;
        }

        /// The next entry, or null at the end. The slices are valid until
        /// the next call.
        pub fn next(self: *RangeIterator) Error!?Item {
            const tree = self.tree;
            // A BufferFirstAllocator is two words of state over memory it
            // does not own, and it tells by ADDRESS which of its two sources
            // a slice came from. So a new one per call is fine, and it can
            // free the value that the previous call's one handed out.
            var chain: std.heap.BufferFirstAllocator = .init(&self.inline_buf, tree.gpa);
            const allocator = chain.allocator();
            allocator.free(self.value);
            self.value = &.{};

            while (self.leaf != invalid_page_id) {
                const pinned = self.leaf; // `self.leaf` may move on below
                const page = try tree.pinNode(pinned);
                if (page.kind() != kind_leaf) {
                    tree.pool.unpin(pinned, false);
                    return error.Corrupt;
                }
                if (self.slot >= page.count()) {
                    // End of this leaf: follow the sibling link. No parent
                    // is needed, which is the point of chaining the leaves.
                    self.leaf = link(page);
                    self.slot = 0;
                    tree.pool.unpin(pinned, false);
                    self.hops += 1;
                    if (self.hops > tree.pool.pager.pageCount()) return error.Corrupt;
                    continue;
                }
                const pending = blk: {
                    defer tree.pool.unpin(pinned, false);
                    const key = page.key(self.slot);
                    if (self.hi) |hi| {
                        if (std.mem.order(u8, key, hi) != .lt) {
                            self.leaf = invalid_page_id;
                            return null;
                        }
                    }
                    @memcpy(self.key_buf[0..key.len], key);
                    break :blk .{ key.len, try startValue(allocator, page.value(self.slot)) };
                };
                const key_len, const value = pending;
                // From here on the buffer is the iterator's: `deinit` or the
                // next call frees it, also if the chain cannot be read.
                self.value = value.buf;
                try tree.readChain(value.first, value.buf[value.filled..]);
                self.slot += 1;
                return .{ .key = self.key_buf[0..key_len], .value = self.value };
            }
            return null;
        }

        /// True if the current value did not fit the inline buffer.
        pub fn valueOnHeap(self: *const RangeIterator) bool {
            const start = @intFromPtr(&self.inline_buf);
            const at = @intFromPtr(self.value.ptr);
            return self.value.len > 0 and (at < start or at >= start + inline_len);
        }
    };

    // ---- validate -------------------------------------------------------------

    /// Check invariants T1 to T10 (see the top of the file) by reading every
    /// page of the file.
    pub fn validate(self: *DiskBTree) (Error || ValidateError)!void {
        defer _ = self.arena.reset(.retain_capacity);
        const roles = try self.arena.allocator().alloc(Role, self.pool.pager.pageCount());
        try self.assignRoles(roles);
    }

    /// `validate`, returning the role it found for every page (the caller
    /// frees the slice): the file's page map.
    pub fn pageMap(self: *DiskBTree, allocator: Allocator) (Error || ValidateError)![]Role {
        defer _ = self.arena.reset(.retain_capacity);
        const roles = try allocator.alloc(Role, self.pool.pager.pageCount());
        errdefer allocator.free(roles);
        try self.assignRoles(roles);
        return roles;
    }

    fn assignRoles(self: *DiskBTree, roles: []Role) (Error || ValidateError)!void {
        @memset(roles, .unseen);
        var walk: Walk = .{ .tree = self, .roles = roles };
        roles[meta_page_id] = .meta;
        try walk.visit(self.root, null, null, 0);

        for (walk.leaves.items, 1..) |leaf, i| {
            const expected = if (i < walk.leaves.items.len) walk.leaves.items[i].id else invalid_page_id;
            if (leaf.next != expected) return error.LeafChainBroken; // T5
        }
        if (walk.keys != self.key_count) return error.KeyCountMismatch; // T8
        try walk.freeList(); // T10
        if (std.mem.indexOfScalar(Role, roles, .unseen) != null) return error.UnreachablePage; // T6
    }

    const Walk = struct {
        tree: *DiskBTree,
        roles: []Role,
        /// The leaves in the order the tree reaches them, with their links.
        leaves: std.ArrayList(struct { id: PageId, next: PageId }) = .empty,
        leaf_depth: ?usize = null,
        keys: u64 = 0,

        /// Give page `id` its role; it must not have one yet (T6).
        fn claim(w: *Walk, id: PageId, role: Role) ValidateError!void {
            const old = w.roles[id];
            if (old != .unseen) return if (old.family() == role.family()) error.PageReachedTwice else error.PageInTwoRoles;
            w.roles[id] = role;
        }

        /// `lo` (inclusive) and `hi` (exclusive) are the bounds the
        /// ancestors' separators put on this subtree; null = unbounded.
        fn visit(w: *Walk, id: PageId, lo: ?[]const u8, hi: ?[]const u8, depth: usize) (Error || ValidateError)!void {
            const pool = w.tree.pool;
            const scratch = w.tree.arena.allocator();
            if (id >= w.roles.len) return error.BadPage;
            if (depth >= max_height) return error.UnevenDepth; // T4
            // Claimed as a leaf for now; corrected below.
            try w.claim(id, .leaf);

            const buf = try pool.fetchPage(id);
            var pinned = true;
            defer if (pinned) pool.unpin(id, false);
            var page = SlottedPage.open(buf);
            // `nodeIsSound` is safe on any bytes; everything after it may
            // trust the page. Checked here every time: `validate` is also
            // for pages this handle has changed.
            if (!nodeIsSound(page)) return error.BadPage; // T1, T2
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
                // The leaf stays pinned while its chains are walked: two pins.
                for (0..n) |i| try w.chain(parseField(page.value(i)) catch return error.BadCell); // T9
                return;
            }
            if (n == 0 and id == w.tree.root) return error.EmptyPage; // T7
            w.roles[id] = .interior;

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

        /// T9: the chain of one value has exactly the pages its length asks
        /// for, each an overflow page that no other cell uses.
        fn chain(w: *Walk, ref: ValueRef) (Error || ValidateError)!void {
            const pool = w.tree.pool;
            var id = ref.first;
            for (0..overflowPages(ref.total)) |_| {
                if (id >= w.roles.len) return error.OverflowChainBroken; // includes "ended early"
                try w.claim(id, .overflow);
                const page = try pool.fetchPage(id);
                const kind = page[off_kind];
                const next = plainNext(page);
                pool.unpin(id, false);
                if (kind != kind_overflow) return error.OverflowChainBroken;
                id = next;
            }
            if (id != invalid_page_id) return error.OverflowChainBroken;
        }

        /// T10. A loop in the list is caught by `claim`.
        fn freeList(w: *Walk) (Error || ValidateError)!void {
            const pool = w.tree.pool;
            var listed: u64 = 0;
            var id = w.tree.free_head;
            while (id != invalid_page_id) {
                if (id >= w.roles.len) return error.FreeListBroken;
                try w.claim(id, .trunk);
                const pinned = id;
                const page = try pool.fetchPage(pinned);
                defer pool.unpin(pinned, false);
                const n = trunkCount(page);
                if (page[off_kind] != kind_trunk or n > trunk_capacity) return error.FreeListBroken;
                for (0..n) |i| {
                    const free = std.mem.readInt(u32, trunkEntry(page, i), .little);
                    if (free >= w.roles.len) return error.FreeListBroken;
                    try w.claim(free, .free);
                }
                listed += 1 + n;
                id = plainNext(page);
            }
            if (listed != w.tree.free_count) return error.FreeListBroken;
        }
    };

    // ---- inspection -------------------------------------------------------------

    /// Number of levels: 1 for a root that is a leaf.
    pub fn height(self: *DiskBTree) Error!u32 {
        var levels: u32 = 1;
        var id = self.root;
        while (levels <= max_height) : (levels += 1) {
            const page = try self.pinNode(id);
            const child = if (page.kind() == kind_leaf) null else childAt(page, 0);
            self.pool.unpin(id, false);
            id = child orelse return levels;
        }
        return error.Corrupt;
    }

    /// Print the tree, one page per line, children indented under their
    /// parent, then the free list. Keys are printed as text, with every
    /// byte that is not printable ASCII as `\xNN` (keys are arbitrary bytes,
    /// and Zig and Rust must print the same). A value is printed as its length; a value with a chain as
    /// `total=local+[overflow page ids]`.
    ///
    /// Bounded on a damaged file: the tree part prints at most as many pages
    /// as the file has and stops with `Corrupt` after that, the free list
    /// part prints at most that many trunks and then says that it loops.
    pub fn dump(self: *DiskBTree, w: *Io.Writer) (Error || Io.Writer.Error)!void {
        defer _ = self.arena.reset(.retain_capacity);
        const pages = self.pool.pager.pageCount();
        var budget: usize = pages;
        try self.dumpPage(w, self.root, 0, &budget);
        try w.print("free list: {d} pages", .{self.free_count});
        var id = self.free_head;
        var trunks: usize = 0;
        while (id != invalid_page_id) : (trunks += 1) {
            if (trunks == pages) {
                try w.writeAll(" | ... (the list loops)");
                break;
            }
            const pinned = id;
            const trunk = try self.pinPlain(pinned, kind_trunk);
            defer self.pool.unpin(pinned, false);
            try w.print(" | trunk {d}:", .{pinned});
            for (0..@min(trunkCount(trunk), trunk_capacity)) |i| try w.print(" {d}", .{std.mem.readInt(u32, trunkEntry(trunk, i), .little)});
            id = plainNext(trunk);
        }
        try w.writeAll("\n");
    }

    /// A key for `dump`: printable ASCII as it is, any other byte as `\xNN`.
    fn escapeKey(key: []const u8) std.ascii.HexEscape {
        return std.ascii.hexEscape(key, .lower);
    }

    fn dumpPage(self: *DiskBTree, w: *Io.Writer, id: PageId, depth: usize, budget: *usize) (Error || Io.Writer.Error)!void {
        // A page reached twice is printed twice, so a loop among the child
        // pointers would print for ever without these two bounds.
        if (depth >= max_height or budget.* == 0) return error.Corrupt;
        budget.* -= 1;
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
            for (0..n) |i| {
                const ref = try parseField(page.value(i));
                try w.print(" {f}:{d}", .{ escapeKey(page.key(i)), ref.total });
                if (ref.first == invalid_page_id) continue;
                try w.print("={d}+[", .{ref.local.len});
                var at = ref.first;
                for (0..overflowPages(ref.total)) |j| {
                    try w.print("{s}{d}", .{ if (j == 0) "" else " ", at });
                    const pinned_at = at;
                    const overflow = try self.pinPlain(pinned_at, kind_overflow);
                    at = plainNext(overflow);
                    self.pool.unpin(pinned_at, false);
                }
                try w.writeAll("]");
            }
            try w.writeAll("\n");
            return;
        }
        try w.print("page {d}  interior  {d} keys  {d}/{d} bytes  |", .{ id, n, used, page_capacity });
        const children = try self.arena.allocator().alloc(PageId, n + 1);
        for (children, 0..) |*child, i| {
            child.* = childAt(page, i);
            if (i < n) try w.print(" ({d}) {f}", .{ child.*, escapeKey(page.key(i)) }) else try w.print(" ({d})\n", .{child.*});
        }
        self.pool.unpin(id, false);
        pinned = false;
        for (children) |child| try self.dumpPage(w, child, depth + 1, budget);
    }
};
