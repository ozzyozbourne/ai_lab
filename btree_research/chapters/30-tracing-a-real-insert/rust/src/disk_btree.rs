// Copied from chapters/12-disk-backed-bplus-tree/rust/src/disk_btree.rs. Changes for chapter 30, none of
// which alters what `put` does or which bytes reach the file: the steps of `put` (pin_node,
// push_root_down, split_leaf, insert_separator, split_interior), the types they exchange (PathEntry,
// Carry) and the tree's bookkeeping fields are `pub(crate)`, so that resumable.rs can run the steps
// one by one.
//! disk_btree.rs: a B+tree whose nodes are slotted pages in a file.
//!
//! Layers (each one only talks to the one below):
//!
//! ```text
//!   DiskBTree      this file: keys, splits, the tree shape
//!   SlottedPage    base_slotted_page.rs: cells inside one 4096-byte page
//!   BufferPool     base_buffer_pool.rs: page id -> pinned frame in memory
//!   Pager          base_pager.rs: page id -> byte offset in the storage
//!   Storage        base_storage.rs: a file, or memory with fault injection
//! ```
//!
//! File layout
//! ===========
//!
//! ```text
//!   page 0   metapage (see `Meta`)
//!   page 1   the root, for the whole life of the file
//!   page 2+  leaves and interior pages, in order of allocation
//! ```
//!
//! Every tree page is a slotted page formatted with a 4-byte reserved tail
//! (bytes 4092..4095 stay zero; chapters 21 and 22 put a page checksum there).
//! The slotted page's caller-owned header bytes hold what makes it a node:
//!
//! ```text
//!   kind        1 = leaf, 2 = interior
//!   user area   bytes 0..4: one page id (u32, little-endian), the "link"
//!                 leaf:      the right sibling, or INVALID_PAGE_ID for none
//!                 interior:  the rightmost child
//!
//!   leaf cell      key -> value
//!   interior cell  key -> child page id (4 bytes). Cell i is (K_i, C_i):
//!                  C_i holds the keys k with K_(i-1) <= k < K_i, and the
//!                  rightmost child (the link) holds the keys >= K_(n-1).
//! ```
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
//!       in key order, and ends with INVALID_PAGE_ID
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
//! frames. Difference from Zig: there the scratch memory of an operation
//! comes from an arena that is reset when the operation returns. Here the
//! path stack is a `Vec` owned by the tree and cleared per operation (its
//! capacity is the retained arena), the copy of a page being split is a
//! 4096-byte array on the stack, and the cell lists are short-lived `Vec`s
//! that are dropped at the end of the split.
//!
//! NOT crash-safe, and not error-atomic. A split changes two or three pages
//! and the file only ever receives them one at a time. If `put` fails after
//! its first page change (I/O error), the tree in memory is half-split: the
//! handle marks itself poisoned and refuses further work. If the process
//! dies between the page writes, the file is half-split. Chapters 21 and 22
//! repair this with checksums and a write-ahead log.

use std::fmt;

use crate::base_buffer_pool::BufferPool;
pub use crate::base_pager::{INVALID_PAGE_ID, PAGE_SIZE, Page, PageId};
use crate::base_slotted_page::{self as slotted, PageError, SlottedPage};
use crate::base_storage::Error as IoError;

pub const META_PAGE_ID: PageId = 0;
pub const MAGIC: &[u8; 8] = b"BTREE12\0";
pub const FORMAT_VERSION: u32 = 1;
/// Bytes at the end of every page that the tree never touches.
pub const RESERVED_TAIL: u8 = 4;

pub const KIND_LEAF: u8 = 1;
pub const KIND_INTERIOR: u8 = 2;

/// Bytes an empty tree page offers to cells and their slots.
pub const PAGE_CAPACITY: usize = PAGE_SIZE - RESERVED_TAIL as usize - slotted::HEADER_SIZE;
pub const MAX_KEY_LEN: usize = 256;
pub const MAX_VALUE_LEN: usize = PAGE_SIZE / 4;
const CHILD_SIZE: usize = size_of::<PageId>();

/// What a cell costs its page: the cell itself plus its slot.
pub const fn cell_cost(key_len: usize, value_len: usize) -> usize {
    slotted::cell_size(key_len, value_len) + slotted::SLOT_SIZE
}

// The split argument (see `split_point`) needs every cell to cost at most a
// third of a page: then a page that overflowed can always be cut into two
// pages that both fit. Postgres has the same rule for the same reason.
const _: () = assert!(3 * cell_cost(MAX_KEY_LEN, MAX_VALUE_LEN) <= PAGE_CAPACITY);
const _: () = assert!(slotted::USER_AREA_SIZE >= CHILD_SIZE);

/// Every way a tree operation can fail. Zig merges error sets with `||`;
/// here the storage, pager and pool errors are wrapped in `Io`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TreeError {
    /// Storage, pager or buffer pool error (`StorageFailure`, ...).
    Io(IoError),
    /// `create` on a storage that already has pages.
    NotEmpty,
    /// `open`: page 0 is not a metapage of this format.
    BadMagic,
    UnsupportedVersion,
    /// A page is not what the tree expects there (wrong kind, a link that
    /// leaves the file, a metapage that contradicts the file).
    Corrupt,
    KeyTooLarge,
    ValueTooLarge,
    /// An earlier `put` failed half-way through a split.
    TreePoisoned,
    /// `validate` found a broken invariant.
    Invalid(Violation),
}

/// Zig's `ValidateError`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Violation {
    BadPage,          // T1, T2
    KeyOutOfBounds,   // T3
    UnevenDepth,      // T4
    LeafChainBroken,  // T5
    PageReachedTwice, // T6
    UnreachablePage,  // T6
    EmptyPage,        // T7
    KeyCountMismatch, // T8
}

impl fmt::Display for TreeError {
    /// Prints like Zig's `error.{t}`.
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            TreeError::Io(e) => write!(f, "{e}"),
            TreeError::Invalid(v) => write!(f, "error.{v:?}"),
            other => write!(f, "error.{other:?}"),
        }
    }
}

impl std::error::Error for TreeError {}

impl From<IoError> for TreeError {
    fn from(e: IoError) -> Self {
        TreeError::Io(e)
    }
}

type Result<T> = std::result::Result<T, TreeError>;

/// The metapage, page 0. Little-endian, like every integer on disk.
///
/// ```text
///    0  [8]  magic "BTREE12\0"
///    8  u32  format version (1)
///   12  u32  page size (4096)
///   16  u32  root page id (always 1 in this chapter; stored so that later
///            formats, or several trees in one file, can differ)
///   20  u32  page count  } as of the last `flush`; between flushes the
///   24  u64  key count   } file can be ahead of them
///   ..       zero; the last 4 bytes are reserved like on every other page
/// ```
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Meta {
    pub root: PageId,
    pub page_count: u32,
    pub key_count: u64,
}

impl Meta {
    fn encode(&self, buf: &mut Page) {
        buf.fill(0);
        buf[0..8].copy_from_slice(MAGIC);
        buf[8..12].copy_from_slice(&FORMAT_VERSION.to_le_bytes());
        buf[12..16].copy_from_slice(&(PAGE_SIZE as u32).to_le_bytes());
        buf[16..20].copy_from_slice(&self.root.to_le_bytes());
        buf[20..24].copy_from_slice(&self.page_count.to_le_bytes());
        buf[24..32].copy_from_slice(&self.key_count.to_le_bytes());
    }

    fn decode(buf: &Page) -> Result<Meta> {
        let u32_at = |at: usize| u32::from_le_bytes(buf[at..at + 4].try_into().expect("4 bytes"));
        if &buf[0..8] != MAGIC {
            return Err(TreeError::BadMagic);
        }
        if u32_at(8) != FORMAT_VERSION || u32_at(12) != PAGE_SIZE as u32 {
            return Err(TreeError::UnsupportedVersion);
        }
        Ok(Meta {
            root: u32_at(16),
            page_count: u32_at(20),
            key_count: u64::from_le_bytes(buf[24..32].try_into().expect("8 bytes")),
        })
    }
}

// ---- a slotted page seen as a tree node ------------------------------------

/// The page id in the user area: right sibling (leaf) or rightmost child.
pub fn link(page: &SlottedPage) -> PageId {
    u32::from_le_bytes(page.user_area()[0..4].try_into().expect("4 bytes"))
}

fn set_link(page: &mut SlottedPage, id: PageId) {
    page.user_area_mut()[0..4].copy_from_slice(&id.to_le_bytes());
}

/// Child `i` of an interior page, 0 <= i <= count (count = the rightmost).
pub fn child_at(page: &SlottedPage, i: usize) -> PageId {
    if i == page.count() {
        return link(page);
    }
    u32::from_le_bytes(page.value(i)[0..4].try_into().expect("4 bytes"))
}

/// Which child of an interior page leads to `key`: the first cell whose key
/// is greater than `key`, or the rightmost child if there is none. A key
/// equal to a separator goes right of it.
pub fn child_index(page: &SlottedPage, key: &[u8]) -> usize {
    let r = page.search(key);
    if r.found { r.index + 1 } else { r.index }
}

/// Cut a list of cell costs in two "50/50 by bytes": the left part is the
/// shortest prefix that holds at least half of the bytes. Returns its length
/// k, with 1 <= k <= costs.len() - min_right.
///
/// Why both halves fit. A page overflowed, so the costs add up to T with
/// capacity < T <= capacity + m, where m is the largest cost allowed. The
/// prefix of length k - 1 is below T/2, so the left half is below T/2 + m
/// <= capacity/2 + 3m/2, which is <= capacity because m <= capacity/3. The
/// right half is at most T/2. The same T > capacity with m <= capacity/3
/// means there are at least 4 cells, so neither half is empty.
pub fn split_point(costs: &[usize], min_right: usize) -> usize {
    let total: usize = costs.iter().sum();
    let last = costs.len() - min_right;
    let mut left = 0;
    for (i, cost) in costs[..last].iter().enumerate() {
        left += cost;
        if 2 * left >= total {
            return i + 1;
        }
    }
    last
}

/// Fetch and pin page `id` as a tree node. A page that is not a node of this
/// tree (for example a page of zeroes that a crash left behind) is reported
/// as `Corrupt` and not pinned.
///
/// A free function over the pool, not a method of the tree: the returned
/// page then borrows only `tree.pool`, and the tree's other fields stay
/// usable while it is alive.
pub(crate) fn pin_node(pool: &mut BufferPool, id: PageId) -> Result<SlottedPage<'_>> {
    if id == META_PAGE_ID || id >= pool.pager().page_count() {
        return Err(TreeError::Corrupt);
    }
    let known = {
        let page = SlottedPage::open(pool.fetch_page(id)?);
        (page.kind() == KIND_LEAF || page.kind() == KIND_INTERIOR)
            && page.reserved_size() == RESERVED_TAIL as usize
    };
    if !known {
        pool.unpin(id, false);
        return Err(TreeError::Corrupt);
    }
    // Difference from Zig: the pin and the borrow are separate things here,
    // so the page is borrowed again now that the check is done.
    Ok(SlottedPage::open(pool.page_mut(id)))
}

fn write_leaf(buf: &mut Page, next: PageId, cells: &[(&[u8], &[u8])]) {
    let mut page = SlottedPage::init_reserved(buf, RESERVED_TAIL);
    page.set_kind(KIND_LEAF);
    set_link(&mut page, next);
    for (i, (key, value)) in cells.iter().enumerate() {
        page.insert_at(i, key, value).expect("see split_point");
    }
}

fn write_interior(buf: &mut Page, rightmost: PageId, entries: &[(&[u8], PageId)]) {
    let mut page = SlottedPage::init_reserved(buf, RESERVED_TAIL);
    page.set_kind(KIND_INTERIOR);
    set_link(&mut page, rightmost);
    for (i, (key, child)) in entries.iter().enumerate() {
        page.insert_at(i, key, &child.to_le_bytes())
            .expect("see split_point");
    }
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Stats {
    pub leaf_splits: u64,
    pub interior_splits: u64,
    /// Times the root's content moved down one level (the height grew).
    pub root_splits: u64,
}

#[derive(Debug, Clone, Copy)]
pub(crate) struct PathEntry {
    pub(crate) id: PageId,
    pub(crate) index: usize,
}

/// What a split hands to the level above: `left` kept the keys below `sep`,
/// the new page `right` got the keys from `sep` on.
pub(crate) struct Carry {
    pub(crate) sep: Vec<u8>,
    pub(crate) left: PageId,
    pub(crate) right: PageId,
}

pub struct DiskBTree {
    /// Owned (Zig borrows a `*BufferPool`): the pool owns the pager, which
    /// owns the storage. `into_pool` gives it back.
    pub(crate) pool: BufferPool,
    /// Scratch of the operation in progress: the interior pages passed on
    /// the way down and the child index taken in each.
    path: Vec<PathEntry>,
    pub(crate) root: PageId,
    pub(crate) key_count: u64,
    /// Set when a `put` failed between two page changes of a split.
    pub(crate) poisoned: bool,
    pub stats: Stats,
}

impl DiskBTree {
    // ---- create / open / close ----------------------------------------------

    /// Format an empty storage: metapage on page 0, an empty leaf as the root
    /// on page 1. Both are written and synced before this returns.
    pub fn create(mut pool: BufferPool) -> Result<Self> {
        if pool.pager().page_count() != 0 {
            return Err(TreeError::NotEmpty);
        }
        let (meta_id, _) = pool.new_page()?;
        pool.unpin(meta_id, true);
        let (root_id, buf) = pool.new_page()?;
        let mut page = SlottedPage::init_reserved(buf, RESERVED_TAIL);
        page.set_kind(KIND_LEAF);
        set_link(&mut page, INVALID_PAGE_ID);
        pool.unpin(root_id, true);
        assert!(meta_id == META_PAGE_ID && root_id == 1);

        let mut tree = Self::with_meta(pool, root_id, 0);
        tree.flush()?;
        Ok(tree)
    }

    /// Open an existing tree. Only the metapage is read here.
    pub fn open(mut pool: BufferPool) -> Result<Self> {
        let pages = pool.pager().page_count();
        if pages < 2 {
            return Err(TreeError::BadMagic);
        }
        let decoded = Meta::decode(pool.fetch_page(META_PAGE_ID)?);
        pool.unpin(META_PAGE_ID, false);
        let meta = decoded?;
        // A file with MORE pages than the metapage says was not flushed
        // after its last allocation; `validate` will find the orphans. A
        // file with fewer pages has lost part of the tree.
        if meta.root == META_PAGE_ID || meta.root >= pages || meta.page_count > pages {
            return Err(TreeError::Corrupt);
        }
        Ok(Self::with_meta(pool, meta.root, meta.key_count))
    }

    fn with_meta(pool: BufferPool, root: PageId, key_count: u64) -> Self {
        Self {
            pool,
            path: Vec::new(),
            root,
            key_count,
            poisoned: false,
            stats: Stats::default(),
        }
    }

    /// Bring the file up to date: write the metapage, write every dirty
    /// page, sync. The pages go out one after the other, in frame order, so
    /// a crash in the middle leaves a mix of old and new pages.
    pub fn flush(&mut self) -> Result<()> {
        if self.poisoned {
            return Err(TreeError::TreePoisoned);
        }
        let meta = Meta {
            root: self.root,
            page_count: self.pool.pager().page_count(),
            key_count: self.key_count,
        };
        meta.encode(self.pool.fetch_page(META_PAGE_ID)?);
        self.pool.unpin(META_PAGE_ID, true);
        self.pool.flush_all()?;
        Ok(())
    }

    /// `flush`, then drop the tree and its pool (also when the flush fails).
    /// Dropping WITHOUT `close` loses whatever was not flushed.
    pub fn close(mut self) -> Result<()> {
        self.flush()
    }

    pub fn pool(&self) -> &BufferPool {
        &self.pool
    }

    /// For tests and tools that want to look at (or damage) pages directly.
    pub fn pool_mut(&mut self) -> &mut BufferPool {
        &mut self.pool
    }

    /// Give the pool back without flushing.
    pub fn into_pool(self) -> BufferPool {
        self.pool
    }

    pub fn root(&self) -> PageId {
        self.root
    }

    pub fn key_count(&self) -> u64 {
        self.key_count
    }

    pub fn is_poisoned(&self) -> bool {
        self.poisoned
    }

    // ---- get ----------------------------------------------------------------

    /// The value stored under `key`, as an owned copy, or None. A copy,
    /// because the page it lives on may be evicted as soon as this function
    /// has unpinned it.
    pub fn get(&mut self, key: &[u8]) -> Result<Option<Vec<u8>>> {
        if self.poisoned {
            return Err(TreeError::TreePoisoned);
        }
        let leaf_id = self.find_leaf(key, false)?;
        let leaf = pin_node(&mut self.pool, leaf_id)?;
        let value = leaf.get(key).map(<[u8]>::to_vec);
        self.pool.unpin(leaf_id, false);
        Ok(value)
    }

    /// Walk from the root to the leaf that owns `key`, one pin at a time: a
    /// parent is unpinned before its child is fetched, which is fine without
    /// concurrency (chapter 19 is about when it is not). With `record_path`,
    /// `self.path` receives the interior pages passed and the child index
    /// taken in each. Returns the leaf's page id, not pinned.
    fn find_leaf(&mut self, key: &[u8], record_path: bool) -> Result<PageId> {
        self.path.clear();
        let mut id = self.root;
        loop {
            let page = pin_node(&mut self.pool, id)?;
            if page.kind() == KIND_LEAF {
                self.pool.unpin(id, false);
                return Ok(id);
            }
            let index = child_index(&page, key);
            let child = child_at(&page, index);
            self.pool.unpin(id, false);
            if record_path {
                self.path.push(PathEntry { id, index });
            }
            id = child;
        }
    }

    // ---- put ----------------------------------------------------------------

    /// Insert `key`, or replace its value if it is already there.
    pub fn put(&mut self, key: &[u8], value: &[u8]) -> Result<()> {
        if self.poisoned {
            return Err(TreeError::TreePoisoned);
        }
        if key.len() > MAX_KEY_LEN {
            return Err(TreeError::KeyTooLarge);
        }
        if value.len() > MAX_VALUE_LEN {
            return Err(TreeError::ValueTooLarge);
        }

        let leaf_id = self.find_leaf(key, true)?;
        let mut leaf = pin_node(&mut self.pool, leaf_id)?;
        let existed = leaf.search(key).found;
        match leaf.put(key, value) {
            // The common case: one page changed, in memory.
            Ok(()) => self.pool.unpin(leaf_id, true),
            Err(PageError::CellTooLarge) => unreachable!("excluded by the length checks"),
            Err(PageError::PageFull) => {
                self.pool.unpin(leaf_id, false);
                self.split_and_insert(leaf_id, key, value)?;
            }
        }
        if !existed {
            self.key_count += 1;
        }
        Ok(())
    }

    /// The leaf `leaf_id` has no room for (key, value). Split it, then hand
    /// the separator to the parent; if the parent has no room either, split
    /// that too, and so on up the remembered path. Splits therefore run
    /// bottom-up: only now, at the leaf, do we know that a split is needed
    /// and how many bytes the parent must take.
    fn split_and_insert(&mut self, leaf_id: PageId, key: &[u8], value: &[u8]) -> Result<()> {
        // Each step is all-or-nothing by itself, but the steps are not
        // atomic together. Once one has changed a page, a failure in a later
        // one leaves the tree half-split. (Zig says this with one `errdefer`;
        // here the steps run in an inner function and the result is checked.)
        let mut changed = false;
        let result = self.split_steps(leaf_id, key, value, &mut changed);
        if result.is_err() && changed {
            self.poisoned = true;
        }
        result
    }

    fn split_steps(
        &mut self,
        leaf_id: PageId,
        key: &[u8],
        value: &[u8],
        changed: &mut bool,
    ) -> Result<()> {
        let mut id = leaf_id;
        if self.path.is_empty() {
            // The leaf is the root. The root never splits: its content
            // moves down first, and the page below it splits.
            id = self.push_root_down()?;
            *changed = true;
            self.path.push(PathEntry {
                id: self.root,
                index: 0,
            });
        }
        let mut carry = self.split_leaf(id, key, value)?;
        *changed = true;

        loop {
            let mut parent = self.path.pop().expect("a split page has a parent");
            if self.insert_separator(parent, &carry)? {
                return Ok(());
            }
            if self.path.is_empty() {
                // The full parent is the root: same move, one level up. The
                // child index stays valid because the cells moved unchanged.
                parent.id = self.push_root_down()?;
                self.path.push(PathEntry {
                    id: self.root,
                    index: 0,
                });
            }
            carry = self.split_interior(parent, &carry)?;
        }
    }

    /// Grow the tree by one level WITHOUT changing the root's page id: copy
    /// the root page into a new page and turn the root into an interior page
    /// with no key and that new page as its only (rightmost) child. Returns
    /// the new page, which the caller then splits like any other page.
    /// Fails before changing anything.
    pub(crate) fn push_root_down(&mut self) -> Result<PageId> {
        let root_id = self.root;
        self.pool.fetch_page(root_id)?;
        let child_id = match self.pool.new_page() {
            Ok((id, _)) => id,
            Err(e) => {
                self.pool.unpin(root_id, false);
                return Err(e.into());
            }
        };
        let (root, child) = self.pool.page_pair_mut(root_id, child_id);
        // A slotted page has no pointers into itself, only offsets, so its
        // bytes mean the same thing at any page id.
        *child = *root;
        let mut page = SlottedPage::init_reserved(root, RESERVED_TAIL);
        page.set_kind(KIND_INTERIOR);
        set_link(&mut page, child_id);
        self.pool.unpin(child_id, true);
        self.pool.unpin(root_id, true);
        self.stats.root_splits += 1;
        Ok(child_id)
    }

    /// Split leaf `id` around the new cell. The left half stays on page
    /// `id`, so the leaf that pointed at it still does; the right half goes
    /// to a new page and is linked in after it. Fails before changing
    /// anything.
    pub(crate) fn split_leaf(&mut self, id: PageId, key: &[u8], value: &[u8]) -> Result<Carry> {
        // The split buffer: a copy of the page (on the stack), so that both
        // halves can be rebuilt from it. The cells below borrow from it.
        let mut copy: Page = *self.pool.fetch_page(id)?;
        let old = SlottedPage::open(&mut copy);
        let r = old.search(key);
        let n = old.count() + usize::from(!r.found);
        let mut cells: Vec<(&[u8], &[u8])> = Vec::with_capacity(n);
        for i in 0..n {
            // Slot i of the result: the old cells with the new one inserted
            // at r.index, or put in place of the old cell with the same key.
            if i == r.index {
                cells.push((key, value));
            } else {
                let from = if i < r.index || r.found { i } else { i - 1 };
                cells.push((old.key(from), old.value(from)));
            }
        }
        let costs: Vec<usize> = cells
            .iter()
            .map(|(k, v)| cell_cost(k.len(), v.len()))
            .collect();
        let k = split_point(&costs, 1);

        // The last step that can fail.
        let right_id = match self.pool.new_page() {
            Ok((right_id, _)) => right_id,
            Err(e) => {
                self.pool.unpin(id, false);
                return Err(e.into());
            }
        };
        let (left_buf, right_buf) = self.pool.page_pair_mut(id, right_id);
        write_leaf(left_buf, right_id, &cells[..k]);
        write_leaf(right_buf, link(&old), &cells[k..]);
        self.pool.unpin(right_id, true);
        self.pool.unpin(id, true);
        self.stats.leaf_splits += 1;
        // The separator is a COPY of the right half's first key: in a B+tree
        // the key itself stays in the leaf.
        Ok(Carry {
            sep: cells[k].0.to_vec(),
            left: id,
            right: right_id,
        })
    }

    /// Record a finished split in the parent: where one pointer led to
    /// `carry.left`, there are now `left`, the separator and `right`.
    /// Returns false, with the parent untouched, if the separator does not
    /// fit.
    pub(crate) fn insert_separator(&mut self, parent: PathEntry, carry: &Carry) -> Result<bool> {
        let mut page = pin_node(&mut self.pool, parent.id)?;
        if page.kind() != KIND_INTERIOR
            || parent.index > page.count()
            || child_at(&page, parent.index) != carry.left
        {
            self.pool.unpin(parent.id, false);
            return Err(TreeError::Corrupt);
        }
        if !page.fits(carry.sep.len(), CHILD_SIZE) {
            self.pool.unpin(parent.id, false);
            return Ok(false);
        }
        // The pointer that led to `left` must now lead to `right`...
        if parent.index == page.count() {
            set_link(&mut page, carry.right);
        } else {
            // (same-size overwrite: happens in place and cannot fail; the
            // key is copied because `put` takes no slice of its own page)
            let old_key = page.key(parent.index).to_vec();
            page.put(&old_key, &carry.right.to_le_bytes())
                .expect("same size");
        }
        // ...and the new cell (sep -> left) goes in front of it.
        page.insert_at(parent.index, &carry.sep, &carry.left.to_le_bytes())
            .expect("fits was checked");
        self.pool.unpin(parent.id, true);
        Ok(true)
    }

    /// Split interior page `parent.id` while inserting the separator of
    /// `carry` at `parent.index`. Unlike in a leaf, the middle key MOVES up:
    /// it separates the two halves and is needed in neither. Fails before
    /// changing anything.
    pub(crate) fn split_interior(&mut self, parent: PathEntry, carry: &Carry) -> Result<Carry> {
        let id = parent.id;
        let mut copy: Page = *self.pool.fetch_page(id)?;
        let old = SlottedPage::open(&mut copy);
        let n = old.count() + 1;
        let mut rightmost = link(&old);
        let mut entries: Vec<(&[u8], PageId)> = Vec::with_capacity(n);
        for i in 0..n {
            entries.push(match i.cmp(&parent.index) {
                std::cmp::Ordering::Less => (old.key(i), child_at(&old, i)),
                std::cmp::Ordering::Equal => (carry.sep.as_slice(), carry.left),
                std::cmp::Ordering::Greater => (old.key(i - 1), child_at(&old, i - 1)),
            });
        }
        // The pointer after the new separator is the one that led to `left`.
        if parent.index + 1 < n {
            entries[parent.index + 1].1 = carry.right;
        } else {
            rightmost = carry.right;
        }
        let costs: Vec<usize> = entries
            .iter()
            .map(|(k, _)| cell_cost(k.len(), CHILD_SIZE))
            .collect();
        // entries[k] moves up; at least one entry must remain right of it.
        let k = split_point(&costs, 2);

        // The last step that can fail.
        let right_id = match self.pool.new_page() {
            Ok((right_id, _)) => right_id,
            Err(e) => {
                self.pool.unpin(id, false);
                return Err(e.into());
            }
        };
        let (left_buf, right_buf) = self.pool.page_pair_mut(id, right_id);
        write_interior(left_buf, entries[k].1, &entries[..k]);
        write_interior(right_buf, rightmost, &entries[k + 1..]);
        self.pool.unpin(right_id, true);
        self.pool.unpin(id, true);
        self.stats.interior_splits += 1;
        Ok(Carry {
            sep: entries[k].0.to_vec(),
            left: id,
            right: right_id,
        })
    }

    // ---- range --------------------------------------------------------------

    /// Iterate over the entries with lo <= key < hi in key order; `hi` None
    /// means "to the end". `lo` = b"" starts at the first key.
    pub fn range(&mut self, lo: &[u8], hi: Option<&[u8]>) -> Result<RangeIterator<'_>> {
        if self.poisoned {
            return Err(TreeError::TreePoisoned);
        }
        let leaf_id = self.find_leaf(lo, false)?;
        let slot = pin_node(&mut self.pool, leaf_id)?.search(lo).index;
        self.pool.unpin(leaf_id, false);
        Ok(RangeIterator {
            tree: self,
            leaf: leaf_id,
            slot,
            hi: hi.map(<[u8]>::to_vec),
            key: Vec::new(),
            value: Vec::new(),
        })
    }

    // ---- validate -------------------------------------------------------------

    /// Check invariants T1 to T8 (see the top of the file) by reading every
    /// page of the file.
    pub fn validate(&mut self) -> Result<()> {
        let mut walk = Walk {
            seen: vec![false; self.pool.pager().page_count() as usize],
            leaves: Vec::new(),
            leaf_depth: None,
            keys: 0,
        };
        walk.seen[META_PAGE_ID as usize] = true;
        self.visit(&mut walk, self.root, None, None, 0)?;

        for (i, &(_, next)) in walk.leaves.iter().enumerate() {
            let expected = walk
                .leaves
                .get(i + 1)
                .map_or(INVALID_PAGE_ID, |&(id, _)| id);
            if next != expected {
                return Err(TreeError::Invalid(Violation::LeafChainBroken)); // T5
            }
        }
        if walk.seen.contains(&false) {
            return Err(TreeError::Invalid(Violation::UnreachablePage)); // T6
        }
        if walk.keys != self.key_count {
            return Err(TreeError::Invalid(Violation::KeyCountMismatch)); // T8
        }
        Ok(())
    }

    /// `lo` (inclusive) and `hi` (exclusive) are the bounds the ancestors'
    /// separators put on this subtree; None = unbounded.
    fn visit(
        &mut self,
        walk: &mut Walk,
        id: PageId,
        lo: Option<&[u8]>,
        hi: Option<&[u8]>,
        depth: usize,
    ) -> Result<()> {
        let invalid = |v: Violation| Err(TreeError::Invalid(v));
        if id as usize >= walk.seen.len() {
            return invalid(Violation::BadPage);
        }
        if walk.seen[id as usize] {
            return invalid(Violation::PageReachedTwice); // T6
        }
        walk.seen[id as usize] = true;

        // Recurse without a pin (the pool may be tiny): work on a copy.
        // (Zig copies only interior pages; a stack copy is cheap enough to
        // make for every page.)
        let mut copy: Page = *self.pool.fetch_page(id)?;
        self.pool.unpin(id, false);
        let page = SlottedPage::open(&mut copy);
        // `SlottedPage::validate` is safe on any bytes; everything after it
        // may trust the page.
        if page.validate().is_err() || page.reserved_size() != RESERVED_TAIL as usize {
            return invalid(Violation::BadPage); // T1, T2
        }
        let n = page.count();
        if n > 0 {
            // T3
            if lo.is_some_and(|bound| page.key(0) < bound) {
                return invalid(Violation::KeyOutOfBounds);
            }
            if hi.is_some_and(|bound| page.key(n - 1) >= bound) {
                return invalid(Violation::KeyOutOfBounds);
            }
        }

        if page.kind() == KIND_LEAF {
            if n == 0 && id != self.root {
                return invalid(Violation::EmptyPage); // T7
            }
            if *walk.leaf_depth.get_or_insert(depth) != depth {
                return invalid(Violation::UnevenDepth); // T4
            }
            walk.keys += n as u64;
            walk.leaves.push((id, link(&page)));
            return Ok(());
        }
        if page.kind() != KIND_INTERIOR {
            return invalid(Violation::BadPage);
        }
        if n == 0 {
            return invalid(Violation::EmptyPage); // T7
        }
        for i in 0..=n {
            let child_lo = if i == 0 { lo } else { Some(page.key(i - 1)) };
            let child_hi = if i == n { hi } else { Some(page.key(i)) };
            self.visit(walk, child_at(&page, i), child_lo, child_hi, depth + 1)?;
        }
        Ok(())
    }

    // ---- inspection -------------------------------------------------------------

    /// Number of levels: 1 for a root that is a leaf.
    pub fn height(&mut self) -> Result<u32> {
        let mut levels = 1;
        let mut id = self.root;
        loop {
            let page = pin_node(&mut self.pool, id)?;
            let child = (page.kind() != KIND_LEAF).then(|| child_at(&page, 0));
            self.pool.unpin(id, false);
            match child {
                Some(child) => id = child,
                None => return Ok(levels),
            }
            levels += 1;
        }
    }

    /// The tree as text, one page per line, children indented under their
    /// parent. Keys are printed as text and values as their length, so this
    /// is meant for trees with printable keys. (Zig prints to a writer.)
    pub fn dump(&mut self) -> Result<String> {
        let mut out = String::new();
        self.dump_page(&mut out, self.root, 0)?;
        Ok(out)
    }

    fn dump_page(&mut self, out: &mut String, id: PageId, depth: usize) -> Result<()> {
        use std::fmt::Write;
        let page = pin_node(&mut self.pool, id)?;
        let n = page.count();
        let used = PAGE_CAPACITY - page.free_bytes();
        let text = |bytes: &[u8]| String::from_utf8_lossy(bytes).into_owned();
        out.push_str(&"  ".repeat(depth));
        // Writing to a String cannot fail.
        if page.kind() == KIND_LEAF {
            let _ = write!(
                out,
                "page {id}  leaf      {n} keys  {used}/{PAGE_CAPACITY} bytes  next "
            );
            match link(&page) {
                INVALID_PAGE_ID => out.push('-'),
                next => out.push_str(&next.to_string()),
            }
            out.push_str("  |");
            for i in 0..n {
                let _ = write!(out, " {}:{}", text(page.key(i)), page.value(i).len());
            }
            out.push('\n');
            self.pool.unpin(id, false);
            return Ok(());
        }
        let _ = write!(
            out,
            "page {id}  interior  {n} keys  {used}/{PAGE_CAPACITY} bytes  |"
        );
        let children: Vec<PageId> = (0..=n).map(|i| child_at(&page, i)).collect();
        for (i, child) in children.iter().enumerate() {
            if i < n {
                let _ = write!(out, " ({child}) {}", text(page.key(i)));
            } else {
                let _ = writeln!(out, " ({child})");
            }
        }
        self.pool.unpin(id, false);
        for child in children {
            self.dump_page(out, child, depth + 1)?;
        }
        Ok(())
    }
}

/// What `validate` collects on its way through the tree.
struct Walk {
    seen: Vec<bool>,
    /// The leaves in the order the tree reaches them: (id, link).
    leaves: Vec<(PageId, PageId)>,
    leaf_depth: Option<usize>,
    keys: u64,
}

/// A position in the leaf level: (leaf page id, slot). It holds no pin
/// between calls, so there is nothing to release; each `next` pins the leaf,
/// copies one entry into the iterator's own buffers and unpins.
///
/// Difference from Zig: the iterator borrows the tree mutably, so the rule
/// "do not modify the tree while an iterator is in use" (a split would move
/// the entries under it) is checked by the compiler here and is only a
/// comment there.
pub struct RangeIterator<'a> {
    tree: &'a mut DiskBTree,
    leaf: PageId,
    slot: usize,
    hi: Option<Vec<u8>>,
    key: Vec<u8>,
    value: Vec<u8>,
}

impl RangeIterator<'_> {
    /// The next entry, or None at the end. The slices are valid until the
    /// next call, which is why this cannot be `std::iter::Iterator`: its
    /// items may not borrow from the iterator.
    #[allow(clippy::should_implement_trait)]
    pub fn next(&mut self) -> Result<Option<(&[u8], &[u8])>> {
        while self.leaf != INVALID_PAGE_ID {
            let pool = &mut self.tree.pool;
            let pinned = self.leaf;
            let page = pin_node(pool, pinned)?;
            if page.kind() != KIND_LEAF {
                pool.unpin(pinned, false);
                return Err(TreeError::Corrupt);
            }
            if self.slot < page.count() {
                let key = page.key(self.slot);
                if self.hi.as_deref().is_some_and(|hi| key >= hi) {
                    self.leaf = INVALID_PAGE_ID;
                    pool.unpin(pinned, false);
                    return Ok(None);
                }
                self.key.clear();
                self.key.extend_from_slice(key);
                self.value.clear();
                self.value.extend_from_slice(page.value(self.slot));
                self.slot += 1;
                pool.unpin(pinned, false);
                return Ok(Some((&self.key, &self.value)));
            }
            // End of this leaf: follow the sibling link. No parent is
            // needed, which is the point of chaining the leaves.
            self.leaf = link(&page);
            self.slot = 0;
            pool.unpin(pinned, false);
        }
        Ok(None)
    }
}
