//! Chapter 17: key compression and deduplication on an in-memory page model.
//!
//! A B+tree of byte-string keys whose pages are measured in BYTES, like a real
//! on-disk page, but whose cells are ordinary slices (no slotted-page encoding:
//! that was chapter 10). Three ideas are implemented:
//!
//!   1. Suffix truncation: the separator created by a leaf split is the
//!      shortest byte string that still separates the two halves.
//!   2. The heap TID (row address) is the last key column, so every index
//!      entry is unique and duplicates of a user key have one correct order.
//!   3. Deduplication: equal keys in a full leaf are merged into one cell with
//!      a sorted TID array (a posting list) before the page is allowed to split.
//!
//! The order used EVERYWHERE is `compareTuple`: key bytes first, then TID,
//! where a missing TID (a truncated one) is minus infinity.
//!
//! The one routing rule, kept by every page and checked by `validate`:
//!
//!     low fence  <  every tuple on the page  <=  high fence
//!
//! so a separator S in a parent sends tuples <= S left and tuples > S right.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Order = std.math.Order;

/// Row address. 6 bytes on disk in Postgres (block number + slot); here a
/// plain integer below 2^48 so that ordering is integer ordering.
pub const Tid = u64;
/// The largest TID that fits in the 6 bytes every size formula charges for
/// one. `put` rejects anything larger: otherwise the byte accounting would
/// describe a page that could not be written.
pub const max_tid: Tid = (1 << 48) - 1;
pub const PageId = u32;

// ---- byte accounting (what a cell would cost in a slotted page) ----
pub const header_bytes = 8; // page header
pub const slot_bytes = 2; // slot array entry pointing at the cell
pub const len_bytes = 2; // key length + flag bits
pub const tid_bytes = 6;
pub const child_bytes = 4; // child page id in a pivot
pub const count_bytes = 2; // number of TIDs in a posting list

/// Root-to-leaf paths are kept in fixed arrays; 32 levels is far more than a
/// tree with at least two children per page can reach.
pub const max_height = 32;

pub const Config = struct {
    page_size: usize = 4096,
    /// Suffix truncation of new leaf separators. Off = the full last-left
    /// tuple (key and TID) becomes the separator, as in Lehman and Yao.
    truncate: bool = true,
    /// Run a deduplication pass on a full leaf before splitting it.
    dedup: bool = true,
};

/// A separator / fence key. `tid == null` means the TID was truncated away
/// and compares as minus infinity.
pub const Sep = struct { key: []const u8, tid: ?Tid };

/// A leaf cell: one key and its TIDs in ascending order. One TID is a plain
/// entry, more than one is a posting list.
pub const LeafCell = struct { key: []const u8, tids: []Tid };

pub const Entry = struct { key: []const u8, tid: Tid };

pub const Error = error{ OutOfMemory, KeyTooLarge, TidTooLarge };

/// The total order of the tree. Shorter key sorts first when one is a prefix
/// of the other (std.mem.order does that), which is exactly "truncated bytes
/// are minus infinity". A null TID sorts before every real TID.
pub fn compareTuple(a_key: []const u8, a_tid: ?Tid, b_key: []const u8, b_tid: ?Tid) Order {
    const by_key = std.mem.order(u8, a_key, b_key);
    if (by_key != .eq) return by_key;
    const a = a_tid orelse return if (b_tid == null) .eq else .lt;
    const b = b_tid orelse return .gt;
    return std.math.order(a, b);
}

pub fn commonPrefixLen(a: []const u8, b: []const u8) usize {
    const n = @min(a.len, b.len);
    var i: usize = 0;
    while (i < n and a[i] == b[i]) i += 1;
    return i;
}

/// The separator for a split between `last_left` and `first_right`
/// (precondition: last_left < first_right in tuple order).
/// Postcondition: last_left <= sep < first_right.
/// The result borrows the key bytes of its arguments.
pub fn separator(truncate: bool, last_left: LeafCell, first_right: LeafCell) Sep {
    if (truncate) {
        // Keep the common prefix plus ONE more byte of first_right. That byte
        // is where the two keys differ (or last_left has already ended), so
        // the result is > last_left.key and, having no TID, < first_right.
        const n = commonPrefixLen(last_left.key, first_right.key);
        if (n < first_right.key.len) return .{ .key = first_right.key[0 .. n + 1], .tid = null };
        // n == first_right.key.len: the keys are equal. No byte can tell the
        // halves apart; only the TID can. Fall through.
    }
    // Lehman and Yao's choice: the last tuple on the left, in full.
    return .{ .key = last_left.key, .tid = last_left.tids[last_left.tids.len - 1] };
}

pub fn sepSize(sep: ?Sep) usize {
    const s = sep orelse return 0; // -inf / +inf fences cost nothing
    return slot_bytes + len_bytes + s.key.len + (if (s.tid != null) @as(usize, tid_bytes) else 0);
}

pub fn pivotSize(sep: Sep) usize {
    return sepSize(sep) + child_bytes;
}

pub fn leafCellSize(key_len: usize, n_tids: usize) usize {
    const payload = if (n_tids == 1) tid_bytes else count_bytes + n_tids * tid_bytes;
    return slot_bytes + len_bytes + key_len + payload;
}

fn leafBytes(low: ?Sep, high: ?Sep, cells: []const LeafCell) usize {
    var total = header_bytes + sepSize(low) + sepSize(high);
    for (cells) |c| total += leafCellSize(c.key.len, c.tids.len);
    return total;
}

fn internalBytes(low: ?Sep, high: ?Sep, seps: []const Sep) usize {
    // The first child has no separator: a pivot with an empty key
    // ("minus infinity" in Postgres terms).
    var total = header_bytes + sepSize(low) + sepSize(high) + slot_bytes + len_bytes + child_bytes;
    for (seps) |s| total += pivotSize(s);
    return total;
}

pub const Page = struct {
    /// Owns every byte this page refers to (fence keys, cell keys, TID
    /// arrays, the lists below). A page is rebuilt by filling a NEW arena and
    /// dropping the old one, never by freeing cells one at a time.
    arena: std.heap.ArenaAllocator,
    is_leaf: bool,
    /// Fence keys: copies of the separators that bracket this page in its
    /// parent. null = minus infinity (low) / plus infinity (high).
    low: ?Sep = null,
    high: ?Sep = null,
    right: ?PageId = null,
    cells: std.ArrayList(LeafCell) = .empty, // leaf only
    seps: std.ArrayList(Sep) = .empty, // internal only; seps.len + 1 == children.len
    children: std.ArrayList(PageId) = .empty,
    /// Arena bytes that deletes made unreachable (chapter 10's "fragmented
    /// bytes"). When this exceeds a page, the leaf is rebuilt.
    dead_bytes: usize = 0,

    pub fn usedBytes(p: *const Page) usize {
        return if (p.is_leaf) leafBytes(p.low, p.high, p.cells.items) else internalBytes(p.low, p.high, p.seps.items);
    }
};

fn dupeSep(a: Allocator, sep: ?Sep) Allocator.Error!?Sep {
    const s = sep orelse return null;
    return .{ .key = try a.dupe(u8, s.key), .tid = s.tid };
}

pub const Stats = struct {
    height: usize = 0,
    leaf_pages: usize = 0,
    internal_pages: usize = 0,
    entries: usize = 0, // (key, TID) pairs
    leaf_cells: usize = 0,
    posting_cells: usize = 0,
    seps: usize = 0, // separators in internal pages
    sep_bytes: usize = 0, // their key bytes plus 6 for each kept TID
    children: usize = 0,
    used_bytes: usize = 0, // sum of usedBytes over all pages
};

pub const Counters = struct {
    leaf_splits: usize = 0,
    internal_splits: usize = 0,
    dedup_passes: usize = 0, // passes that made the new tuple fit (a split avoided)
    posting_swaps: usize = 0,
};

const Path = struct {
    steps: [max_height]Step = undefined,
    len: usize = 0,
    const Step = struct { page: PageId, child_index: usize };
};

/// Where a (key, tid) tuple is, or belongs, in a leaf.
const Slot = union(enum) {
    /// Already present: TID number `pos` of cell `cell`.
    found: struct { cell: usize, pos: usize },
    /// Absent; a new plain cell goes at this index.
    insert_at: usize,
    /// Absent, but the TID falls inside the TID range of posting list `cell`,
    /// at position `pos`.
    inside: struct { cell: usize, pos: usize },
};

pub const Tree = struct {
    gpa: Allocator,
    cfg: Config,
    pages: std.ArrayList(Page) = .empty,
    root: PageId = 0,
    count: usize = 0,
    counters: Counters = .{},
    /// Scratch memory for ONE put: the flattened cell list of the page being
    /// split or deduplicated. Bounded by the page size, so it is allocated
    /// once and handed out by a FixedBufferAllocator that is reset per put.
    scratch_buf: []u8,
    scratch: std.heap.FixedBufferAllocator,

    pub fn init(gpa: Allocator, cfg: Config) Allocator.Error!Tree {
        // Not std.debug.assert: that check vanishes in ReleaseFast, where a
        // smaller page would make maxKeyLen underflow. A panic in every build
        // mode matches Rust's assert!.
        if (cfg.page_size < 128) @panic("page_size must be at least 128 bytes");
        // Worst case per put, in units of the page size: two lists of 32-byte
        // LeafCells (10 bytes per cell on the page: 3.2 each), the merged TID
        // arrays (8 bytes per 6-byte TID: 1.4), one internal page as Sep and
        // PageId lists (4.5). 16 leaves a comfortable margin.
        const buf = try gpa.alloc(u8, cfg.page_size * 16);
        errdefer gpa.free(buf);
        var tree: Tree = .{ .gpa = gpa, .cfg = cfg, .scratch_buf = buf, .scratch = .init(buf) };
        // The tree starts as one empty leaf that is also the root.
        try tree.pages.ensureTotalCapacity(gpa, 1);
        errdefer tree.pages.deinit(gpa);
        tree.pages.appendAssumeCapacity(try tree.buildLeaf(null, null, null, &.{}));
        return tree;
    }

    pub fn deinit(self: *Tree) void {
        for (self.pages.items) |p| p.arena.deinit();
        self.pages.deinit(self.gpa);
        self.gpa.free(self.scratch_buf);
        self.* = undefined;
    }

    /// Largest cell of any kind: one sixth of the usable page. With cells and
    /// fences this small, a balanced split of an overflowing page always
    /// yields two pages that fit (see README, "Why one sixth").
    pub fn maxCell(self: *const Tree) usize {
        return (self.cfg.page_size - header_bytes) / 6;
    }

    /// Longest key accepted: it must still fit as a pivot WITH an appended
    /// TID, because a split between equal keys cannot truncate anything.
    /// (Postgres reserves the same room: BTMaxItemSize, nbtree.h:165-173.)
    pub fn maxKeyLen(self: *const Tree) usize {
        return self.maxCell() - (slot_bytes + len_bytes + tid_bytes + child_bytes);
    }

    fn maxPostingTids(self: *const Tree, key_len: usize) usize {
        return (self.maxCell() - (slot_bytes + len_bytes + count_bytes) - key_len) / tid_bytes;
    }

    // ---------------------------------------------------------------- search

    /// Child to follow for a tuple: the number of separators strictly below
    /// it. Works unchanged whether separators are full tuples or truncated
    /// prefixes, because `compareTuple` is the only thing it asks.
    pub fn childIndex(page: *const Page, key: []const u8, tid: Tid) usize {
        var lo: usize = 0;
        var hi: usize = page.seps.items.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const s = page.seps.items[mid];
            if (compareTuple(s.key, s.tid, key, tid) == .lt) lo = mid + 1 else hi = mid;
        }
        return lo;
    }

    fn findLeaf(self: *const Tree, key: []const u8, tid: Tid, path: *Path) PageId {
        var id = self.root;
        path.len = 0;
        while (true) {
            const page = &self.pages.items[id];
            if (page.is_leaf) return id;
            const i = childIndex(page, key, tid);
            path.steps[path.len] = .{ .page = id, .child_index = i };
            path.len += 1;
            id = page.children.items[i];
        }
    }

    /// Index of the first cell whose (key, first TID) is >= (key, tid).
    fn leafLowerBound(cells: []const LeafCell, key: []const u8, tid: Tid) usize {
        var lo: usize = 0;
        var hi: usize = cells.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (compareTuple(cells[mid].key, cells[mid].tids[0], key, tid) == .lt) lo = mid + 1 else hi = mid;
        }
        return lo;
    }

    fn locate(cells: []const LeafCell, key: []const u8, tid: Tid) Slot {
        const i = leafLowerBound(cells, key, tid);
        if (i < cells.len and cells[i].tids[0] == tid and std.mem.eql(u8, cells[i].key, key))
            return .{ .found = .{ .cell = i, .pos = 0 } };
        // The cell before starts below (key, tid). If it has the same key and
        // its LAST TID is not below tid, the tuple belongs inside its range.
        if (i > 0 and std.mem.eql(u8, cells[i - 1].key, key)) {
            const tids = cells[i - 1].tids;
            if (tid <= tids[tids.len - 1]) {
                var pos: usize = 0;
                while (tids[pos] < tid) pos += 1;
                if (tids[pos] == tid) return .{ .found = .{ .cell = i - 1, .pos = pos } };
                return .{ .inside = .{ .cell = i - 1, .pos = pos } };
            }
        }
        return .{ .insert_at = i };
    }

    pub const Iterator = struct {
        tree: *const Tree,
        page: ?PageId,
        cell: usize,
        pos: usize = 0,
        hi: ?[]const u8, // exclusive upper bound on the key; null = no bound

        pub fn next(it: *Iterator) ?Entry {
            while (true) {
                const p = &it.tree.pages.items[it.page orelse return null];
                if (it.cell >= p.cells.items.len) {
                    // Leaf exhausted (or empty after deletes): follow the chain.
                    it.page = p.right;
                    it.cell = 0;
                    continue;
                }
                const c = p.cells.items[it.cell];
                if (it.hi) |hi| if (std.mem.order(u8, c.key, hi) != .lt) {
                    it.page = null;
                    return null;
                };
                const e: Entry = .{ .key = c.key, .tid = c.tids[it.pos] };
                it.pos += 1;
                if (it.pos == c.tids.len) {
                    it.pos = 0;
                    it.cell += 1;
                }
                return e;
            }
        }
    };

    /// Entries with lo <= key < hi in (key, TID) order. Valid until the next
    /// put or delete. Seeking with TID 0 is "the smallest tuple with this key":
    /// it goes RIGHT of a truncated separator equal to `lo` (null < 0) and
    /// LEFT of a full separator (lo, t), which is where duplicates begin.
    pub fn range(self: *const Tree, lo: []const u8, hi: ?[]const u8) Iterator {
        var path: Path = .{};
        const leaf = self.findLeaf(lo, 0, &path);
        const cell = leafLowerBound(self.pages.items[leaf].cells.items, lo, 0);
        return .{ .tree = self, .page = leaf, .cell = cell, .hi = hi };
    }

    /// All TIDs stored under `key`, ascending. Caller frees.
    pub fn get(self: *const Tree, gpa: Allocator, key: []const u8) Allocator.Error![]Tid {
        var out: std.ArrayList(Tid) = .empty;
        errdefer out.deinit(gpa);
        var it = self.range(key, null);
        while (it.next()) |e| {
            if (!std.mem.eql(u8, e.key, key)) break;
            try out.append(gpa, e.tid);
        }
        return out.toOwnedSlice(gpa);
    }

    pub fn contains(self: *const Tree, key: []const u8, tid: Tid) bool {
        var path: Path = .{};
        const leaf = self.findLeaf(key, tid, &path);
        return locate(self.pages.items[leaf].cells.items, key, tid) == .found;
    }

    // ------------------------------------------------------------------- put

    /// Insert the tuple (key, tid). Returns false if it is already present.
    /// The key must fit `maxKeyLen` and the TID must fit 6 bytes (`max_tid`).
    /// On error the tree is unchanged.
    pub fn put(self: *Tree, key: []const u8, tid: Tid) Error!bool {
        if (key.len > self.maxKeyLen()) return error.KeyTooLarge;
        if (tid > max_tid) return error.TidTooLarge;
        var path: Path = .{};
        const leaf_id = self.findLeaf(key, tid, &path);
        const leaf = &self.pages.items[leaf_id];
        const slot = locate(leaf.cells.items, key, tid);
        if (slot == .found) return false;

        // Whatever happens, the page grows by exactly one PLAIN cell: either
        // the new tuple, or the TID that the new tuple pushes out of a
        // posting list (see swapIntoPosting).
        if (leaf.usedBytes() + leafCellSize(key.len, 1) <= self.cfg.page_size) {
            // Fast path: room on the page. Do everything that can fail first.
            const a = leaf.arena.allocator();
            try leaf.cells.ensureUnusedCapacity(a, 1);
            const owned_key = try a.dupe(u8, key);
            const one = try a.alloc(Tid, 1);
            switch (slot) {
                .insert_at => |i| {
                    one[0] = tid;
                    leaf.cells.insertAssumeCapacity(i, .{ .key = owned_key, .tids = one });
                },
                .inside => |s| {
                    one[0] = swapIntoPosting(leaf.cells.items[s.cell].tids, s.pos, tid);
                    leaf.cells.insertAssumeCapacity(s.cell + 1, .{ .key = owned_key, .tids = one });
                    self.counters.posting_swaps += 1;
                },
                .found => unreachable,
            }
        } else {
            try self.putSlow(leaf_id, slot, key, tid, &path);
        }
        self.count += 1;
        return true;
    }

    /// Posting list split, Postgres style (`_bt_swap_posting`): the new TID
    /// takes its sorted place inside the list and the list's largest TID is
    /// pushed out, to be inserted as a plain cell right after. The posting
    /// list keeps its size, so the caller only ever has to find room for one
    /// plain cell.
    fn swapIntoPosting(tids: []Tid, pos: usize, tid: Tid) Tid {
        const evicted = tids[tids.len - 1];
        std.mem.copyBackwards(Tid, tids[pos + 1 ..], tids[pos .. tids.len - 1]);
        tids[pos] = tid;
        return evicted;
    }

    /// Pages built by a put that are not part of the tree yet. Either all of
    /// them are installed (`commit`) or all are dropped (`abort`): this is
    /// what makes a multi-level split atomic under allocation failure.
    ///
    /// The array sizes are exact, not generous: `validate` accepts at most
    /// `max_height` levels, so a path has at most max_height - 1 internal
    /// steps; a put then replaces at most one page per level (max_height)
    /// and adds at most one per level plus a new root (max_height + 1).
    const Txn = struct {
        tree: *Tree,
        replaced: [max_height]struct { id: PageId, page: Page } = undefined,
        n_replaced: usize = 0,
        added: [max_height + 1]Page = undefined,
        n_added: usize = 0,
        new_root: ?PageId = null,

        fn nextId(t: *const Txn) PageId {
            return @intCast(t.tree.pages.items.len + t.n_added);
        }
        fn replace(t: *Txn, id: PageId, page: Page) void {
            t.replaced[t.n_replaced] = .{ .id = id, .page = page };
            t.n_replaced += 1;
        }
        fn add(t: *Txn, page: Page) void {
            t.added[t.n_added] = page;
            t.n_added += 1;
        }
        fn abort(t: *Txn) void {
            for (t.replaced[0..t.n_replaced]) |r| r.page.arena.deinit();
            for (t.added[0..t.n_added]) |p| p.arena.deinit();
        }
        fn commit(t: *Txn) void {
            const pages = &t.tree.pages;
            for (t.replaced[0..t.n_replaced]) |r| {
                pages.items[r.id].arena.deinit(); // the old version, all at once
                pages.items[r.id] = r.page;
            }
            for (t.added[0..t.n_added]) |p| pages.appendAssumeCapacity(p); // capacity reserved in putSlow
            if (t.new_root) |r| t.tree.root = r;
        }
    };

    fn putSlow(self: *Tree, leaf_id: PageId, slot: Slot, key: []const u8, tid: Tid, path: *const Path) Error!void {
        // Reserve room for every page this put can add (one per level plus a
        // new root) BEFORE taking pointers into `pages`: nothing below may
        // move the page array, and commit must not be able to fail.
        try self.pages.ensureUnusedCapacity(self.gpa, path.len + 2);
        self.scratch.reset();
        const sa = self.scratch.allocator();
        const old = &self.pages.items[leaf_id];
        const cells = old.cells.items;

        // 1. Flatten: the page's cells plus the new tuple, as borrowed views.
        var items = try sa.alloc(LeafCell, cells.len + 1);
        const one = try sa.alloc(Tid, 1);
        const at = switch (slot) {
            .insert_at => |i| i,
            .inside => |s| s.cell + 1,
            .found => unreachable,
        };
        @memcpy(items[0..at], cells[0..at]);
        @memcpy(items[at + 1 ..], cells[at..]);
        one[0] = tid;
        if (slot == .inside) {
            // Swap on a scratch copy; the real page must stay untouched
            // until commit.
            const copy = try sa.dupe(Tid, cells[at - 1].tids);
            one[0] = swapIntoPosting(copy, slot.inside.pos, tid);
            items[at - 1].tids = copy;
        }
        items[at] = .{ .key = key, .tids = one };

        var txn: Txn = .{ .tree = self };
        errdefer txn.abort();
        var counters = self.counters;
        if (slot == .inside) counters.posting_swaps += 1;

        // 2. Deduplicate before splitting: a split is forever (pages are
        //    never merged back), a posting list is free.
        if (self.cfg.dedup) {
            items = try self.dedupPass(sa, items);
            if (leafBytes(old.low, old.high, items) <= self.cfg.page_size) {
                txn.replace(leaf_id, try self.buildLeaf(old.low, old.high, old.right, items));
                counters.dedup_passes += 1;
                txn.commit();
                self.counters = counters;
                return;
            }
        }

        // 3. Split the leaf. The left half keeps the page id.
        const cut = self.chooseLeafSplit(old.low, old.high, items);
        var sep = separator(self.cfg.truncate, items[cut - 1], items[cut]);
        var left_id = leaf_id;
        var right_id = txn.nextId();
        txn.replace(left_id, try self.buildLeaf(old.low, sep, right_id, items[0..cut]));
        txn.add(try self.buildLeaf(sep, old.high, old.right, items[cut..]));
        counters.leaf_splits += 1;

        // 4. Insert (sep, right_id) into the parent; repeat while parents overflow.
        var level = path.len;
        while (true) {
            if (level == 0) {
                // The page that split was the root: grow the tree by one level.
                const root_id = txn.nextId();
                txn.add(try self.buildInternal(null, null, null, &.{sep}, &.{ left_id, right_id }));
                txn.new_root = root_id;
                break;
            }
            level -= 1;
            const step = path.steps[level];
            const parent = &self.pages.items[step.page];
            const at_sep = step.child_index; // the new separator's index; its child goes one further
            if (parent.usedBytes() + pivotSize(sep) <= self.cfg.page_size) {
                // Room in the parent. This mutates a live page, so it is the
                // LAST fallible step: after it only commit remains.
                const a = parent.arena.allocator();
                try parent.seps.ensureUnusedCapacity(a, 1);
                try parent.children.ensureUnusedCapacity(a, 1);
                const owned = (try dupeSep(a, sep)).?;
                parent.seps.insertAssumeCapacity(at_sep, owned);
                parent.children.insertAssumeCapacity(at_sep + 1, right_id);
                break;
            }
            // Internal split. The FixedBufferAllocator is a stack: remember
            // the top, use it for this level's lists, pop when done.
            const mark = self.scratch.end_index;
            defer self.scratch.end_index = mark;
            const n = parent.seps.items.len;
            const seps = try sa.alloc(Sep, n + 1);
            const kids = try sa.alloc(PageId, n + 2);
            @memcpy(seps[0..at_sep], parent.seps.items[0..at_sep]);
            seps[at_sep] = sep;
            @memcpy(seps[at_sep + 1 ..], parent.seps.items[at_sep..]);
            @memcpy(kids[0 .. at_sep + 1], parent.children.items[0 .. at_sep + 1]);
            kids[at_sep + 1] = right_id;
            @memcpy(kids[at_sep + 2 ..], parent.children.items[at_sep + 1 ..]);

            // seps[m] moves UP and is not truncated any further: it must stay
            // byte-identical to the leaf-level fence it came from.
            // Its key bytes live in an old page or in the caller's key, both
            // alive until commit, so popping the scratch stack is safe.
            const m = self.chooseInternalSplit(parent.low, parent.high, seps);
            const up = seps[m];
            const new_right = txn.nextId();
            txn.replace(step.page, try self.buildInternal(parent.low, up, new_right, seps[0..m], kids[0 .. m + 1]));
            txn.add(try self.buildInternal(up, parent.high, parent.right, seps[m + 1 ..], kids[m + 1 ..]));
            counters.internal_splits += 1;
            sep = up;
            left_id = step.page;
            right_id = new_right;
        }
        txn.commit();
        self.counters = counters;
    }

    /// Merge runs of equal keys into posting lists (Postgres:
    /// `_bt_dedup_pass`). The cells are already in (key, TID) order and the
    /// TID ranges of equal keys do not overlap, so concatenating is enough.
    fn dedupPass(self: *const Tree, sa: Allocator, items: []const LeafCell) Allocator.Error![]LeafCell {
        const out = try sa.alloc(LeafCell, items.len);
        var n: usize = 0;
        var i: usize = 0;
        while (i < items.len) {
            const cap = self.maxPostingTids(items[i].key.len);
            var total = items[i].tids.len;
            var j = i + 1;
            while (j < items.len and std.mem.eql(u8, items[j].key, items[i].key) and total + items[j].tids.len <= cap) : (j += 1) {
                total += items[j].tids.len;
            }
            if (j == i + 1) {
                out[n] = items[i];
            } else {
                const merged = try sa.alloc(Tid, total);
                var k: usize = 0;
                for (items[i..j]) |c| {
                    @memcpy(merged[k..][0..c.tids.len], c.tids);
                    k += c.tids.len;
                }
                out[n] = .{ .key = items[i].key, .tids = merged };
            }
            n += 1;
            i = j;
        }
        return out[0..n];
    }

    /// Where to cut `items` (left = items[0..cut]). Among the cuts that leave
    /// both halves between 40% and 60% of the cell bytes, take the one with
    /// the SHORTEST separator; otherwise the most balanced one. (A small
    /// version of the Postgres idea in nbtsplitloc.c; chapter 14 has the
    /// full story of split policies.)
    fn chooseLeafSplit(self: *const Tree, low: ?Sep, high: ?Sep, items: []const LeafCell) usize {
        var total: usize = 0;
        for (items) |c| total += leafCellSize(c.key.len, c.tids.len);
        var best: ?usize = null;
        var best_score: [3]usize = undefined;
        var left: usize = 0;
        for (1..items.len) |cut| {
            left += leafCellSize(items[cut - 1].key.len, items[cut - 1].tids.len);
            const sep = separator(self.cfg.truncate, items[cut - 1], items[cut]);
            const fence = sepSize(sep);
            if (header_bytes + sepSize(low) + fence + left > self.cfg.page_size) continue;
            if (header_bytes + fence + sepSize(high) + (total - left) > self.cfg.page_size) continue;
            const imbalance = if (2 * left > total) 2 * left - total else total - 2 * left;
            const in_window = imbalance * 5 <= total;
            const score: [3]usize = if (in_window) .{ 0, fence, imbalance } else .{ 1, 0, imbalance };
            if (best == null or std.mem.order(usize, &score, &best_score) == .lt) {
                best = cut;
                best_score = score;
            }
        }
        return best.?; // a legal cut exists because no cell exceeds maxCell
    }

    /// Index of the separator that moves up: the most balanced legal one.
    fn chooseInternalSplit(self: *const Tree, low: ?Sep, high: ?Sep, seps: []const Sep) usize {
        var total: usize = 0;
        for (seps) |s| total += pivotSize(s);
        const fixed = header_bytes + slot_bytes + len_bytes + child_bytes;
        var best: ?usize = null;
        var best_imbalance: usize = 0;
        var left: usize = 0;
        for (seps, 0..) |s, m| {
            const right = total - left - pivotSize(s);
            const fits = fixed + sepSize(low) + sepSize(s) + left <= self.cfg.page_size and
                fixed + sepSize(s) + sepSize(high) + right <= self.cfg.page_size;
            const imbalance = if (left > right) left - right else right - left;
            if (fits and (best == null or imbalance < best_imbalance)) {
                best = m;
                best_imbalance = imbalance;
            }
            left += pivotSize(s);
        }
        return best.?;
    }

    /// A fresh leaf in its own arena, holding copies of everything it is given.
    fn buildLeaf(self: *const Tree, low: ?Sep, high: ?Sep, right: ?PageId, items: []const LeafCell) Allocator.Error!Page {
        var page: Page = .{ .arena = .init(self.gpa), .is_leaf = true, .right = right };
        errdefer page.arena.deinit();
        const a = page.arena.allocator();
        page.low = try dupeSep(a, low);
        page.high = try dupeSep(a, high);
        try page.cells.ensureTotalCapacity(a, items.len + 1);
        for (items) |c| {
            page.cells.appendAssumeCapacity(.{ .key = try a.dupe(u8, c.key), .tids = try a.dupe(Tid, c.tids) });
        }
        return page;
    }

    fn buildInternal(self: *const Tree, low: ?Sep, high: ?Sep, right: ?PageId, seps: []const Sep, children: []const PageId) Allocator.Error!Page {
        var page: Page = .{ .arena = .init(self.gpa), .is_leaf = false, .right = right };
        errdefer page.arena.deinit();
        const a = page.arena.allocator();
        page.low = try dupeSep(a, low);
        page.high = try dupeSep(a, high);
        try page.seps.ensureTotalCapacity(a, seps.len + 1);
        for (seps) |s| page.seps.appendAssumeCapacity((try dupeSep(a, s)).?);
        try page.children.ensureTotalCapacity(a, children.len + 1);
        page.children.appendSliceAssumeCapacity(children);
        return page;
    }

    // ---------------------------------------------------------------- delete

    /// Remove the tuple (key, tid). Returns false if it is absent. Pages are
    /// never merged (Postgres does not merge either; chapters 15 and 24), so
    /// a leaf may become empty; scans step over it.
    pub fn delete(self: *Tree, key: []const u8, tid: Tid) bool {
        var path: Path = .{};
        const leaf_id = self.findLeaf(key, tid, &path);
        const leaf = &self.pages.items[leaf_id];
        const at = switch (locate(leaf.cells.items, key, tid)) {
            .found => |f| f,
            else => return false,
        };
        const cell = &leaf.cells.items[at.cell];
        leaf.dead_bytes += @sizeOf(Tid);
        if (cell.tids.len == 1) {
            leaf.dead_bytes += cell.key.len;
            _ = leaf.cells.orderedRemove(at.cell);
        } else {
            // Shrink the posting list in place. With one TID left it simply
            // counts as a plain cell again (see leafCellSize).
            std.mem.copyForwards(Tid, cell.tids[at.pos .. cell.tids.len - 1], cell.tids[at.pos + 1 ..]);
            cell.tids.len -= 1;
        }
        self.count -= 1;
        // The arena cannot give those bytes back one by one. Once a page's
        // worth is dead, rebuild the leaf into a new arena ("compaction").
        // Best effort: if memory is short the old page stays, still correct.
        if (leaf.dead_bytes > self.cfg.page_size) {
            if (self.buildLeaf(leaf.low, leaf.high, leaf.right, leaf.cells.items)) |fresh| {
                leaf.arena.deinit();
                leaf.* = fresh;
            } else |_| {}
        }
        return true;
    }

    // -------------------------------------------------------------- validate

    const Check = struct {
        leaf_depth: ?usize = null,
        /// The page met last at each depth. The DFS meets the pages of one
        /// level left to right, so each one must be the `right` of the one
        /// before: a sibling chain per level, leaves and internal pages alike.
        prev_at: [max_height]?PageId = @splat(null),
        entries: usize = 0,
    };

    /// Check every invariant of the structure. `error.Corrupt` on the first violation.
    pub fn validate(self: *const Tree) error{Corrupt}!void {
        var st: Check = .{};
        try self.checkPage(self.root, null, null, 0, &st);
        // Every level's chain must end at the last page the DFS met there.
        for (st.prev_at[0 .. st.leaf_depth.? + 1]) |last| {
            if (self.pages.items[last.?].right != null) return error.Corrupt;
        }
        if (st.entries != self.count) return error.Corrupt;
    }

    fn sameFence(a: ?Sep, b: ?Sep) bool {
        const x = a orelse return b == null;
        const y = b orelse return false;
        return compareTuple(x.key, x.tid, y.key, y.tid) == .eq;
    }

    /// low < (key, tid): a null low fence is minus infinity.
    fn aboveLow(low: ?Sep, key: []const u8, tid: ?Tid) bool {
        const l = low orelse return true;
        return compareTuple(l.key, l.tid, key, tid) == .lt;
    }

    /// (key, tid) <= high if `inclusive`, else <: a null high fence is plus infinity.
    fn belowHigh(high: ?Sep, key: []const u8, tid: ?Tid, inclusive: bool) bool {
        const h = high orelse return true;
        const o = compareTuple(key, tid, h.key, h.tid);
        return o == .lt or (inclusive and o == .eq);
    }

    fn checkPage(self: *const Tree, id: PageId, low: ?Sep, high: ?Sep, depth: usize, st: *Check) error{Corrupt}!void {
        if (id >= self.pages.items.len or depth >= max_height) return error.Corrupt;
        const p = &self.pages.items[id];
        // Fence keys: the page's own copy must equal what the parent says.
        // This is what lets a page be verified without looking at its parent.
        if (!sameFence(p.low, low) or !sameFence(p.high, high)) return error.Corrupt;
        if (p.usedBytes() > self.cfg.page_size) return error.Corrupt;
        // The sibling chain of this level (the leaf chain at the bottom).
        if (st.prev_at[depth]) |prev| if (self.pages.items[prev].right != id) return error.Corrupt;
        st.prev_at[depth] = id;

        if (p.is_leaf) {
            if (st.leaf_depth) |d| {
                if (d != depth) return error.Corrupt; // all leaves at one depth
            } else st.leaf_depth = depth;

            var prev_cell: ?LeafCell = null;
            for (p.cells.items) |c| {
                if (c.tids.len == 0 or c.key.len > self.maxKeyLen()) return error.Corrupt;
                if (c.tids[c.tids.len - 1] > max_tid) return error.Corrupt; // must fit 6 bytes
                if (leafCellSize(c.key.len, c.tids.len) > self.maxCell()) return error.Corrupt;
                for (c.tids[1..], c.tids[0 .. c.tids.len - 1]) |t, before| if (before >= t) return error.Corrupt;
                // Strictly ascending in (key, TID) order across cells.
                if (prev_cell) |pc| {
                    if (compareTuple(pc.key, pc.tids[pc.tids.len - 1], c.key, c.tids[0]) != .lt) return error.Corrupt;
                }
                // low < every tuple <= high.
                if (!aboveLow(low, c.key, c.tids[0])) return error.Corrupt;
                if (!belowHigh(high, c.key, c.tids[c.tids.len - 1], true)) return error.Corrupt;
                prev_cell = c;
                st.entries += c.tids.len;
            }
            return;
        }

        const seps = p.seps.items;
        if (p.children.items.len != seps.len + 1 or seps.len == 0) return error.Corrupt;
        for (seps, 0..) |s, i| {
            if (s.key.len > self.maxKeyLen()) return error.Corrupt;
            // low < seps[0] < seps[1] < ... < high
            const below: ?Sep = if (i == 0) low else seps[i - 1];
            if (!aboveLow(below, s.key, s.tid)) return error.Corrupt;
            if (!belowHigh(high, s.key, s.tid, false)) return error.Corrupt;
        }
        for (p.children.items, 0..) |child, i| {
            const child_low: ?Sep = if (i == 0) low else seps[i - 1];
            const child_high: ?Sep = if (i == seps.len) high else seps[i];
            try self.checkPage(child, child_low, child_high, depth + 1, st);
        }
    }

    // ----------------------------------------------------------------- stats

    pub fn stats(self: *const Tree) Stats {
        var s: Stats = .{ .entries = self.count };
        var id = self.root;
        while (true) : (id = self.pages.items[id].children.items[0]) {
            s.height += 1;
            if (self.pages.items[id].is_leaf) break;
        }
        // Pages are never freed, so every page in the array is in the tree.
        for (self.pages.items) |*p| {
            s.used_bytes += p.usedBytes();
            if (p.is_leaf) {
                s.leaf_pages += 1;
                s.leaf_cells += p.cells.items.len;
                for (p.cells.items) |c| {
                    if (c.tids.len > 1) s.posting_cells += 1;
                }
            } else {
                s.internal_pages += 1;
                s.children += p.children.items.len;
                s.seps += p.seps.items.len;
                for (p.seps.items) |sep| s.sep_bytes += sep.key.len + (if (sep.tid != null) @as(usize, tid_bytes) else 0);
            }
        }
        return s;
    }
};
