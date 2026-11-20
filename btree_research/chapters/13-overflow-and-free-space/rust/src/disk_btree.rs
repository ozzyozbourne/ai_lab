// Copied from chapters/12-disk-backed-bplus-tree/rust/src/disk_btree.rs and extended:
// overflow chains, `delete` with free-at-empty, the on-disk free list, a
// wider `validate`. The split code (push_root_down, split_leaf,
// insert_separator, split_interior, split_point) is chapter 12's, with
// `pool.new_page()` replaced by `alloc_page()` and an order check added to
// `insert_separator`.
//! disk_btree.rs: a B+tree of slotted pages with large values and a free list.
//!
//! Layers (each one only talks to the one below):
//!
//! ```text
//!   DiskBTree      this file: keys, splits, overflow chains, the free list
//!   SlottedPage    base_slotted_page.rs: cells inside one 4096-byte page
//!   BufferPool     base_buffer_pool.rs: page id -> pinned frame in memory
//!   Pager          base_pager.rs: page id -> byte offset in the storage
//!   Storage        base_storage.rs: a file, or memory with fault injection
//! ```
//!
//! Every page of the file has exactly ONE of these roles
//! =====================================================
//!
//! ```text
//!   metapage   page 0 (see `Meta`)
//!   tree page  a leaf or an interior page reachable from the root (page 1)
//!   overflow   one link of the chain that holds the tail of ONE large value
//!   trunk      a page of the free list: an array of free page ids
//!   free       a page listed in a trunk; its content means nothing
//! ```
//!
//! Byte 7 of every formatted page says what it was last formatted as (the
//! slotted page's `kind` byte; overflow and trunk pages keep theirs at the
//! same offset), and the last 4 bytes of every page stay zero, reserved for
//! the checksum of chapters 21 and 22.
//!
//! ```text
//!   tree page (kind 1 = leaf, 2 = interior): a slotted page, as in chapter 12
//!     user area bytes 0..4: the link (leaf: right sibling; interior:
//!     rightmost child). Interior cell i is (K_i -> child with keys < K_i).
//!
//!   leaf cell: key -> value field
//!       0   u32  total length of the value, P
//!       4   the first local_len(P) bytes of the value
//!       ..  u32  first overflow page    (only if P > MAX_LOCAL)
//!
//!   overflow page (kind 3)
//!       0   u32  next overflow page, INVALID_PAGE_ID = last
//!       7   u8   kind
//!       8   payload, OVERFLOW_PAYLOAD = 4084 bytes; every page of a chain
//!           is full except possibly the last
//!
//!   trunk page (kind 4)
//!       0   u32  next trunk page, INVALID_PAGE_ID = last
//!       4   u16  n, the number of ids that follow
//!       7   u8   kind
//!       8   n * u32 free page ids, at most TRUNK_CAPACITY = 1021
//! ```
//!
//! Invariants (checked by `validate`)
//!   T1  every tree page is a well-formed slotted page of a known kind
//!   T2  keys are strictly ascending inside a page
//!   T3  every key of a subtree lies inside the bounds its ancestors'
//!       separators give it: lower bound inclusive, upper bound exclusive
//!   T4  all leaves are at the same depth, and there are at most
//!       `MAX_HEIGHT` levels
//!   T5  following the links from the leftmost leaf visits every leaf once,
//!       in key order, and ends with INVALID_PAGE_ID
//!   T6  every page has exactly one role: none is unreachable, none is
//!       reached twice, none has two roles
//!   T7  no empty page: only the root may be a leaf without cells, and the
//!       root is never an interior page without keys (a non-root interior
//!       page may have no key, but it always has one child)
//!   T8  the number of keys in the leaves equals `key_count`
//!   T9  every value field is well formed, and its overflow chain has
//!       exactly overflow_pages(P) pages of kind 3
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
//! This file makes the same pool calls in the same order as its Zig twin,
//! so both write byte-identical files and count the same hits and misses.
//!
//! The file is untrusted input. Every count, length and page id that comes
//! from a page is checked before it is used as an index or followed, and
//! every walk has a bound, so a damaged file gives `Corrupt` (or a wrong
//! answer that `validate` explains), never a panic or an endless loop:
//!
//! ```text
//!   tree page     checked as a whole (`node_is_sound`) the first time this
//!                 handle pins it; see `pin_node`
//!   page id       must lie inside the file and must not be page 0
//!   descent       at most MAX_HEIGHT levels
//!   leaf chain    a scan follows at most as many links as the file has pages
//!   value field   `parse_field`; a chain has exactly overflow_pages(P) pages
//!   trunk         kind byte, count <= TRUNK_CAPACITY, the id handed out
//!   metapage      `open`; the two counters before they are changed
//! ```
//!
//! Memory. Nodes live in the pool's frames. Difference from Zig: there an
//! operation's scratch memory comes from an arena, and a value that is read
//! is assembled by an allocator the caller passes in (a buffer on the stack
//! first, the heap if the value is larger). Stable Rust has no allocator
//! parameter, so the same idea is a type: `ValueBuf` is an inline array plus
//! a `Vec` that is only used for values that do not fit the array.
//!
//! NOT crash-safe, and not error-atomic. An operation changes several pages
//! and the file receives them one at a time. If `put` or `delete` fails after
//! its first page change (I/O error), the handle marks itself poisoned and
//! refuses further work. Worse than in chapter 12: a freed page is REUSED AT
//! ONCE, so after a crash an old leaf cell on disk can point at pages that
//! already hold another value. Chapter 22 fixes this with a log.

use std::fmt;

use crate::base_buffer_pool::BufferPool;
pub use crate::base_pager::{INVALID_PAGE_ID, PAGE_SIZE, Page, PageId};
use crate::base_slotted_page::{self as slotted, PageError, SlottedPage};
use crate::base_storage::Error as IoError;

pub const META_PAGE_ID: PageId = 0;
pub const MAGIC: &[u8; 8] = b"BTREE12\0";
/// 2: the metapage has a free-list head and leaf values carry a length.
/// (Chapter 12 wrote version 1 and refuses this file; this code refuses its.)
pub const FORMAT_VERSION: u32 = 2;
/// Bytes at the end of every page that the tree never touches.
pub const RESERVED_TAIL: u8 = 4;

pub const KIND_LEAF: u8 = 1;
pub const KIND_INTERIOR: u8 = 2;
pub const KIND_OVERFLOW: u8 = 3;
pub const KIND_TRUNK: u8 = 4;
/// Where every page keeps its kind (the slotted page's `kind` byte).
const OFF_KIND: usize = 7;
/// Overflow and trunk pages: 4 bytes of link, 3 spare, the kind byte.
const PLAIN_HEADER: usize = 8;

/// Bytes an empty tree page offers to cells and their slots.
pub const PAGE_CAPACITY: usize = PAGE_SIZE - RESERVED_TAIL as usize - slotted::HEADER_SIZE;
pub const MAX_KEY_LEN: usize = 256;
/// Sixteen pages. The limit is arbitrary now: no value has to fit in a page.
pub const MAX_VALUE_LEN: usize = 65536;
/// No tree has more levels than this, so a descent that goes deeper is in a
/// damaged file (a child pointer that leads back up). Why 32 is out of
/// reach: a level is added only when the root is full, and after a split a
/// page needs at least 7 more separators to fill up again, each of them from
/// a split one level down. A tree with L levels has therefore seen more than
/// 7^(L-2) leaf splits.
pub const MAX_HEIGHT: usize = 32;
const CHILD_SIZE: usize = size_of::<PageId>();

/// What a cell costs its page: the cell itself plus its slot.
pub const fn cell_cost(key_len: usize, value_len: usize) -> usize {
    slotted::cell_size(key_len, value_len) + slotted::SLOT_SIZE
}

/// A value field: 4 bytes of total length in front, and, if the value
/// spilled, 4 bytes of page id behind the local part.
const FIELD_LEN_SIZE: usize = 4;
const FIELD_PTR_SIZE: usize = size_of::<PageId>();

/// X, the most value bytes a leaf cell keeps. The split argument of chapter
/// 12 (see `split_point`) needs every cell to cost at most a third of a page,
/// and that fixes X: take a third of the capacity and subtract everything
/// else a cell with the longest key costs.
///
/// ```text
///   X = 4076/3 - slot 2 - cell header 4 - key 256 - length 4 - page id 4
///     = 1358 - 270 = 1088
/// ```
pub const MAX_LOCAL: usize = PAGE_CAPACITY / 3
    - slotted::SLOT_SIZE
    - slotted::CELL_HEADER_SIZE
    - MAX_KEY_LEN
    - FIELD_LEN_SIZE
    - FIELD_PTR_SIZE;
/// M, the fewest value bytes a spilled value keeps in its leaf: half of X,
/// the proportion SQLite uses for its index pages (32/255 against 64/255).
pub const MIN_LOCAL: usize = MAX_LOCAL / 2;
/// Value bytes on one overflow page.
pub const OVERFLOW_PAYLOAD: usize = PAGE_SIZE - RESERVED_TAIL as usize - PLAIN_HEADER;
/// Free page ids on one trunk page.
pub const TRUNK_CAPACITY: usize =
    (PAGE_SIZE - RESERVED_TAIL as usize - PLAIN_HEADER) / size_of::<PageId>();
/// The longest value field: X local bytes between the length and the id.
pub const MAX_FIELD_LEN: usize = FIELD_LEN_SIZE + MAX_LOCAL + FIELD_PTR_SIZE;

// The one-third rule of chapter 12, now for the LOCAL part of a cell.
const _: () = assert!(3 * cell_cost(MAX_KEY_LEN, MAX_FIELD_LEN) <= PAGE_CAPACITY);
const _: () = assert!(
    MAX_LOCAL == 1088 && MIN_LOCAL == 544 && OVERFLOW_PAYLOAD == 4084 && TRUNK_CAPACITY == 1021
);
const _: () = assert!(slotted::USER_AREA_SIZE >= CHILD_SIZE);

/// How many bytes of a value of `total` bytes stay in the leaf cell. This is
/// SQLite's rule (see the README for the source lines):
///
/// ```text
///   P <= X                     everything is local
///   K = M + (P - M) mod 4084   what is left over after filling whole
///                              overflow pages, counted from M
///   K <= X                     keep K: every overflow page is then FULL
///   otherwise                  keep M: the last overflow page is part full
/// ```
///
/// So the leaf absorbs a remainder of up to X - M = 544 bytes instead of
/// spending a page on it, and otherwise keeps as little as allowed, which
/// leaves room for more cells per leaf.
///
/// ```text
///   P = 1088 -> 1088 local, no chain
///   P = 1089 -> K = 1089 > X: 544 local + 545 on one page
///   P = 5000 -> K = 544 + 4456 mod 4084 = 916: 916 local + one full page
///   P = 9000 -> K = 544 + 8456 mod 4084 = 832: 832 local + two full pages
/// ```
pub const fn local_len(total: usize) -> usize {
    if total <= MAX_LOCAL {
        return total;
    }
    let k = MIN_LOCAL + (total - MIN_LOCAL) % OVERFLOW_PAYLOAD;
    if k <= MAX_LOCAL { k } else { MIN_LOCAL }
}

/// Length of the overflow chain of a value of `total` bytes, in pages.
pub const fn overflow_pages(total: usize) -> usize {
    (total - local_len(total)).div_ceil(OVERFLOW_PAYLOAD)
}

/// A decoded value field. `local` points into the field.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ValueRef<'a> {
    pub total: usize,
    pub local: &'a [u8],
    /// First page of the overflow chain, or INVALID_PAGE_ID.
    pub first: PageId,
}

fn u32_at(bytes: &[u8], at: usize) -> u32 {
    u32::from_le_bytes(bytes[at..at + 4].try_into().expect("4 bytes"))
}

fn put_u32(bytes: &mut [u8], at: usize, value: u32) {
    bytes[at..at + 4].copy_from_slice(&value.to_le_bytes());
}

/// Decode a leaf cell's value field. Safe on any bytes.
pub fn parse_field(field: &[u8]) -> Result<ValueRef<'_>> {
    if field.len() < FIELD_LEN_SIZE {
        return Err(TreeError::Corrupt);
    }
    let total = u32_at(field, 0) as usize;
    if total > MAX_VALUE_LEN {
        return Err(TreeError::Corrupt);
    }
    let local = local_len(total);
    let spilled = total > MAX_LOCAL;
    if field.len() != FIELD_LEN_SIZE + local + if spilled { FIELD_PTR_SIZE } else { 0 } {
        return Err(TreeError::Corrupt);
    }
    let first = if spilled {
        u32_at(field, field.len() - 4)
    } else {
        INVALID_PAGE_ID
    };
    if spilled && first == INVALID_PAGE_ID {
        return Err(TreeError::Corrupt);
    }
    Ok(ValueRef {
        total,
        local: &field[FIELD_LEN_SIZE..FIELD_LEN_SIZE + local],
        first,
    })
}

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
    /// leaves the file, a chain of the wrong length).
    Corrupt,
    KeyTooLarge,
    ValueTooLarge,
    /// An earlier `put` or `delete` failed half-way.
    TreePoisoned,
    /// `validate` found a broken invariant.
    Invalid(Violation),
}

/// Zig's `ValidateError`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Violation {
    BadPage,             // T1, T2
    KeyOutOfBounds,      // T3
    UnevenDepth,         // T4
    LeafChainBroken,     // T5
    PageReachedTwice,    // T6: twice in the same role
    PageInTwoRoles,      // T6: for example free and in the tree
    UnreachablePage,     // T6
    EmptyPage,           // T7
    KeyCountMismatch,    // T8
    BadCell,             // T9
    OverflowChainBroken, // T9
    FreeListBroken,      // T10
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

fn invalid<T>(v: Violation) -> Result<T> {
    Err(TreeError::Invalid(v))
}

/// The metapage, page 0. Little-endian, like every integer on disk.
///
/// ```text
///    0  [8]  magic "BTREE12\0"
///    8  u32  format version (2)
///   12  u32  page size (4096)
///   16  u32  root page id (always 1)
///   20  u32  page count        }
///   24  u64  key count         } as of the last `flush`; between flushes
///   32  u32  free-list head    } the file can be ahead of them
///   36  u32  free page count   }
///   ..       zero; the last 4 bytes are reserved like on every other page
/// ```
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Meta {
    pub root: PageId,
    pub page_count: u32,
    pub key_count: u64,
    /// First trunk page of the free list, or INVALID_PAGE_ID.
    pub free_head: PageId,
    /// Trunk pages plus the pages they list.
    pub free_count: u32,
}

impl Meta {
    fn encode(&self, buf: &mut Page) {
        buf.fill(0);
        buf[0..8].copy_from_slice(MAGIC);
        put_u32(buf, 8, FORMAT_VERSION);
        put_u32(buf, 12, PAGE_SIZE as u32);
        put_u32(buf, 16, self.root);
        put_u32(buf, 20, self.page_count);
        buf[24..32].copy_from_slice(&self.key_count.to_le_bytes());
        put_u32(buf, 32, self.free_head);
        put_u32(buf, 36, self.free_count);
    }

    fn decode(buf: &Page) -> Result<Meta> {
        if &buf[0..8] != MAGIC {
            return Err(TreeError::BadMagic);
        }
        if u32_at(buf, 8) != FORMAT_VERSION || u32_at(buf, 12) != PAGE_SIZE as u32 {
            return Err(TreeError::UnsupportedVersion);
        }
        Ok(Meta {
            root: u32_at(buf, 16),
            page_count: u32_at(buf, 20),
            key_count: u64::from_le_bytes(buf[24..32].try_into().expect("8 bytes")),
            free_head: u32_at(buf, 32),
            free_count: u32_at(buf, 36),
        })
    }
}

// ---- a slotted page seen as a tree node ------------------------------------

/// The page id in the user area: right sibling (leaf) or rightmost child.
pub fn link(page: &SlottedPage) -> PageId {
    u32_at(page.user_area(), 0)
}

fn set_link(page: &mut SlottedPage, id: PageId) {
    put_u32(page.user_area_mut(), 0, id);
}

/// Child `i` of an interior page, 0 <= i <= count (count = the rightmost).
pub fn child_at(page: &SlottedPage, i: usize) -> PageId {
    if i == page.count() {
        return link(page);
    }
    u32_at(page.value(i), 0)
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

/// Is this page a tree page that the code below can use without looking
/// twice? Safe on any bytes. The slotted page's own `validate` covers
/// everything inside the page (slots, cell bounds, the free blocks, key
/// order); the rest is what the TREE assumes about a cell: a key of at most
/// MAX_KEY_LEN bytes, in a leaf a value field that can be one, in an
/// interior page a 4-byte child id. Without those the one-third rule behind
/// `split_point` would not hold and `child_at` would read past a cell.
pub fn node_is_sound(page: &SlottedPage) -> bool {
    let leaf = page.kind() == KIND_LEAF;
    if !leaf && page.kind() != KIND_INTERIOR {
        return false;
    }
    if page.reserved_size() != RESERVED_TAIL as usize || page.validate().is_err() {
        return false;
    }
    (0..page.count()).all(|i| {
        let len = page.value(i).len();
        page.key(i).len() <= MAX_KEY_LEN
            && if leaf {
                len <= MAX_FIELD_LEN
            } else {
                len == CHILD_SIZE
            }
    })
}

/// Fetch and pin page `id` as a tree node. A page that is not a node of this
/// tree (zeroes, an overflow page, a trunk, damaged bytes) is reported as
/// `Corrupt` and not pinned.
///
/// The slotted page trusts its bytes, so a page from the file must pass
/// `node_is_sound` before anything searches it. That check reads the whole
/// page; it runs ONCE per page and handle, the first time the page is pinned
/// as a node (`checked` is the tree's list of flags). After that the page
/// only changes through this code, in memory or on its way to the file and
/// back. (A checksum, chapter 21, is checked at the same moment for the same
/// reason.)
///
/// A free function over the pool, not a method of the tree: the returned
/// page then borrows only `tree.pool`, and the tree's other fields stay
/// usable while it is alive.
fn pin_node<'a>(
    pool: &'a mut BufferPool,
    checked: &mut [bool],
    id: PageId,
) -> Result<SlottedPage<'a>> {
    if id == META_PAGE_ID || id >= pool.pager().page_count() {
        return Err(TreeError::Corrupt);
    }
    let unchecked = checked.get(id as usize) == Some(&false);
    let known = {
        let page = SlottedPage::open(pool.fetch_page(id)?);
        (page.kind() == KIND_LEAF || page.kind() == KIND_INTERIOR)
            && page.reserved_size() == RESERVED_TAIL as usize
            && (!unchecked || node_is_sound(&page))
    };
    if !known {
        pool.unpin(id, false);
        return Err(TreeError::Corrupt);
    }
    if unchecked {
        checked[id as usize] = true;
    }
    // Difference from Zig: the pin and the borrow are separate things here,
    // so the page is borrowed again now that the check is done.
    Ok(SlottedPage::open(pool.page_mut(id)))
}

/// Fetch and pin page `id` as an overflow or trunk page. The caller reaches
/// the bytes through `pool.page(id)` / `pool.page_mut(id)`.
fn pin_plain(pool: &mut BufferPool, id: PageId, kind: u8) -> Result<()> {
    if id == META_PAGE_ID || id >= pool.pager().page_count() {
        return Err(TreeError::Corrupt);
    }
    if pool.fetch_page(id)?[OFF_KIND] != kind {
        pool.unpin(id, false);
        return Err(TreeError::Corrupt);
    }
    Ok(())
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

// ---- overflow and trunk pages: a link, a kind byte, a payload -----------------

fn plain_next(page: &Page) -> PageId {
    u32_at(page, 0)
}

/// `page` must be zero-filled, as `alloc_page` returns it.
fn format_plain(page: &mut Page, kind: u8, next: PageId) {
    put_u32(page, 0, next);
    page[OFF_KIND] = kind;
}

fn trunk_count(page: &Page) -> usize {
    u16::from_le_bytes([page[4], page[5]]) as usize
}

fn set_trunk_count(page: &mut Page, n: usize) {
    page[4..6].copy_from_slice(&(n as u16).to_le_bytes());
}

/// Byte offset of entry `i` of a trunk page.
const fn trunk_entry(i: usize) -> usize {
    PLAIN_HEADER + 4 * i
}

/// What a page is used for. `validate` assigns one to every page of the file.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Role {
    Unseen,
    Meta,
    Interior,
    Leaf,
    Overflow,
    Trunk,
    Free,
}

impl Role {
    /// One letter per role, for page maps.
    pub fn letter(self) -> char {
        b"?MILOTF"[self as usize] as char
    }

    fn family(self) -> u8 {
        match self {
            Role::Interior | Role::Leaf => 1,
            Role::Trunk | Role::Free => 2,
            other => other as u8 + 3,
        }
    }
}

/// Where a value is assembled: `INLINE_LEN` bytes inside the struct, which
/// is enough for every value that was stored whole in its leaf, and a `Vec`
/// for larger ones. This is what Zig's `BufferFirstAllocator` does for an
/// allocation, written as a type: the caller puts a `ValueBuf` on its stack,
/// and only a value with an overflow chain touches the heap.
///
/// Difference from Zig: the `Vec` keeps its capacity between values, so a
/// scan over many large values allocates once; the Zig iterator frees each
/// large value before it reads the next.
pub struct ValueBuf {
    len: usize,
    inline: [u8; ValueBuf::INLINE_LEN],
    heap: Vec<u8>,
}

impl ValueBuf {
    pub const INLINE_LEN: usize = MAX_LOCAL;

    pub const fn new() -> Self {
        Self {
            len: 0,
            inline: [0; Self::INLINE_LEN],
            heap: Vec::new(),
        }
    }

    /// Make room for a value of `len` bytes and return it for filling.
    fn start(&mut self, len: usize) -> &mut [u8] {
        self.len = len;
        if len > Self::INLINE_LEN {
            self.heap.clear();
            self.heap.resize(len, 0);
        }
        self.as_mut_slice()
    }

    pub fn clear(&mut self) {
        self.len = 0;
    }

    pub fn as_slice(&self) -> &[u8] {
        if self.on_heap() {
            &self.heap[..self.len]
        } else {
            &self.inline[..self.len]
        }
    }

    fn as_mut_slice(&mut self) -> &mut [u8] {
        if self.on_heap() {
            &mut self.heap[..self.len]
        } else {
            &mut self.inline[..self.len]
        }
    }

    /// True if the current value did not fit the inline buffer.
    pub fn on_heap(&self) -> bool {
        self.len > Self::INLINE_LEN
    }

    pub fn into_vec(mut self) -> Vec<u8> {
        if self.on_heap() {
            self.heap.truncate(self.len);
            self.heap
        } else {
            self.inline[..self.len].to_vec()
        }
    }
}

impl Default for ValueBuf {
    fn default() -> Self {
        Self::new()
    }
}

/// Make room in `out` for the whole value behind `field` and copy the local
/// part. Returns how many bytes that was and where the chain for the rest
/// starts. The caller unpins the leaf, then calls `read_chain`.
fn start_value(out: &mut ValueBuf, field: &[u8]) -> Result<(usize, PageId)> {
    let r = parse_field(field)?;
    out.start(r.total)[..r.local.len()].copy_from_slice(r.local);
    Ok((r.local.len(), r.first))
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Stats {
    pub leaf_splits: u64,
    pub interior_splits: u64,
    /// Times the root's content moved down one level (the height grew).
    pub root_splits: u64,
    /// Times the root's only child moved up into it (the height shrank).
    pub root_collapses: u64,
    /// Leaves and interior pages removed from the tree by `delete`.
    pub tree_pages_freed: u64,
    /// How many of those were interior pages.
    pub interior_pages_freed: u64,
    /// Pages handed to the free list (tree pages and overflow pages).
    pub pages_freed: u64,
    /// Allocations served from the free list instead of growing the file.
    pub pages_reused: u64,
    pub overflow_pages_written: u64,
}

#[derive(Debug, Clone, Copy)]
struct PathEntry {
    id: PageId,
    index: usize,
}

/// What a split hands to the level above: `left` kept the keys below `sep`,
/// the new page `right` got the keys from `sep` on.
struct Carry {
    sep: Vec<u8>,
    left: PageId,
    right: PageId,
}

pub struct DiskBTree {
    /// Owned (Zig borrows a `*BufferPool`): the pool owns the pager, which
    /// owns the storage. `into_pool` gives it back.
    pool: BufferPool,
    /// Scratch of the operation in progress: the interior pages passed on
    /// the way down and the child index taken in each.
    path: Vec<PathEntry>,
    root: PageId,
    key_count: u64,
    /// The free list: first trunk page, and how many pages it holds in all.
    free_head: PageId,
    free_count: u32,
    /// One flag per page the file had when it was opened: true once the page
    /// has passed `node_is_sound`. Pages added later are this handle's work.
    checked: Vec<bool>,
    /// True once the operation in progress has changed a page.
    changed: bool,
    /// Set when a `put` or `delete` failed after its first page change.
    poisoned: bool,
    pub stats: Stats,
}

/// A key for `dump`: printable ASCII as it is, any other byte as `\xNN`
/// (what Zig's `std.ascii.hexEscape` prints).
fn escape_key(key: &[u8]) -> String {
    use std::fmt::Write;
    let mut text = String::new();
    for &byte in key {
        if (0x20..=0x7e).contains(&byte) {
            text.push(byte as char);
        } else {
            let _ = write!(text, "\\x{byte:02x}");
        }
    }
    text
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

        let meta = Meta {
            root: root_id,
            page_count: 2,
            key_count: 0,
            free_head: INVALID_PAGE_ID,
            free_count: 0,
        };
        let mut tree = Self::with_meta(pool, meta, 0);
        tree.flush()?;
        Ok(tree)
    }

    /// Open an existing tree. Only the metapage is read here, and every
    /// number in it is checked against the size of the file.
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
        let no_list = meta.free_head == INVALID_PAGE_ID;
        if no_list != (meta.free_count == 0) || meta.free_count >= pages {
            return Err(TreeError::Corrupt);
        }
        if !no_list && (meta.free_head == META_PAGE_ID || meta.free_head >= pages) {
            return Err(TreeError::Corrupt);
        }
        Ok(Self::with_meta(pool, meta, pages as usize))
    }

    /// `unchecked_pages`: how many pages of the file this handle did not
    /// write itself.
    fn with_meta(pool: BufferPool, meta: Meta, unchecked_pages: usize) -> Self {
        Self {
            pool,
            checked: vec![false; unchecked_pages],
            path: Vec::new(),
            root: meta.root,
            key_count: meta.key_count,
            free_head: meta.free_head,
            free_count: meta.free_count,
            changed: false,
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
            free_head: self.free_head,
            free_count: self.free_count,
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

    pub fn free_head(&self) -> PageId {
        self.free_head
    }

    pub fn free_count(&self) -> u32 {
        self.free_count
    }

    pub fn is_poisoned(&self) -> bool {
        self.poisoned
    }

    /// For tests that damage the tree on purpose.
    #[cfg(test)]
    pub(crate) fn counts_mut(&mut self) -> (&mut u64, &mut u32) {
        (&mut self.key_count, &mut self.free_count)
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
    /// formats it (through `pool.page_mut`) and unpins it dirty.
    fn alloc_page(&mut self) -> Result<PageId> {
        if self.free_head == INVALID_PAGE_ID {
            let (id, _) = self.pool.new_page()?;
            self.changed = true;
            return Ok(id);
        }
        let trunk_id = self.free_head;
        pin_plain(&mut self.pool, trunk_id, KIND_TRUNK)?;
        let pages = self.pool.pager().page_count();
        let trunk = self.pool.page_mut(trunk_id);
        // The count comes from the file: check it BEFORE it is used as an
        // index. (And a list that still has a trunk holds at least one page.)
        let n = trunk_count(trunk);
        if n > TRUNK_CAPACITY || self.free_count == 0 {
            self.pool.unpin(trunk_id, false);
            return Err(TreeError::Corrupt);
        }
        if n == 0 {
            // A trunk that lists nothing is itself the next free page.
            self.free_head = plain_next(trunk);
            trunk.fill(0);
            self.took();
            return Ok(trunk_id);
        }
        // Take the LAST id: no other entry moves. The id comes from the file
        // too. A free page is inside the file and nobody has it pinned: a
        // pinned one is this trunk or a page of the operation in progress.
        let id = u32_at(trunk, trunk_entry(n - 1));
        if id == META_PAGE_ID || id >= pages || self.is_pinned(id) {
            self.pool.unpin(trunk_id, false);
            return Err(TreeError::Corrupt);
        }
        let trunk = self.pool.page_mut(trunk_id);
        put_u32(trunk, trunk_entry(n - 1), 0);
        set_trunk_count(trunk, n - 1);
        // Unpin the trunk BEFORE fetching the page: the caller may hold a
        // pin of its own, and two is all a small pool has. The price: if
        // the fetch fails, the id has already left the list (a leaked page;
        // `changed` makes the caller poison the handle).
        self.pool.unpin(trunk_id, true);
        self.took();
        // The pool can only hand out a page by reading it, although the old
        // content is about to be erased (exercise 2).
        self.pool.fetch_page(id)?.fill(0);
        Ok(id)
    }

    /// True if somebody holds a pin on page `id` right now.
    fn is_pinned(&self, id: PageId) -> bool {
        self.pool
            .frame_of(id)
            .is_some_and(|frame| self.pool.frames()[frame].pin_count > 0)
    }

    fn took(&mut self) {
        self.free_count -= 1;
        self.stats.pages_reused += 1;
        self.changed = true;
    }

    /// Put page `id` on the free list. Nothing may point to it any more.
    fn free_page(&mut self, id: PageId) -> Result<()> {
        // Whatever happens below, the page has already left the tree.
        self.changed = true;
        // A list cannot hold more pages than the file has. (This also ends
        // every loop that frees pages of a damaged file again and again.)
        if self.free_count >= self.pool.pager().page_count() {
            return Err(TreeError::Corrupt);
        }
        if self.free_head != INVALID_PAGE_ID {
            let trunk_id = self.free_head;
            pin_plain(&mut self.pool, trunk_id, KIND_TRUNK)?;
            let trunk = self.pool.page_mut(trunk_id);
            let n = trunk_count(trunk);
            if n < TRUNK_CAPACITY {
                // The usual case: one more id in the first trunk. Page `id`
                // is not read and not written; its old bytes stay.
                put_u32(trunk, trunk_entry(n), id);
                set_trunk_count(trunk, n + 1);
                self.pool.unpin(trunk_id, true);
                self.gave();
                return Ok(());
            }
            self.pool.unpin(trunk_id, false);
        }
        // No trunk, or a full one: the freed page becomes the new first
        // trunk, pointing at the old one.
        let page = self.pool.fetch_page(id)?;
        page.fill(0);
        format_plain(page, KIND_TRUNK, self.free_head);
        self.pool.unpin(id, true);
        self.free_head = id;
        self.gave();
        Ok(())
    }

    fn gave(&mut self) {
        self.free_count += 1;
        self.stats.pages_freed += 1;
    }

    // ---- overflow chains ----------------------------------------------------

    /// Encode `value` as a leaf cell's value field. If it is too large for
    /// the leaf, its tail is written to a new overflow chain first: the
    /// field must never point at pages that do not exist yet. (Zig builds
    /// the field in a stack array of MAX_FIELD_LEN bytes.)
    fn write_value(&mut self, value: &[u8]) -> Result<Vec<u8>> {
        let local = local_len(value.len());
        let mut field = Vec::with_capacity(MAX_FIELD_LEN);
        field.extend_from_slice(&(value.len() as u32).to_le_bytes());
        field.extend_from_slice(&value[..local]);
        if local < value.len() {
            let first = self.write_chain(&value[local..])?;
            field.extend_from_slice(&first.to_le_bytes());
        }
        Ok(field)
    }

    /// Write `tail` to a chain of new overflow pages, front to back, and
    /// return the first page. The previous page stays pinned while the next
    /// one is allocated, because only then is the id for its link known.
    fn write_chain(&mut self, tail: &[u8]) -> Result<PageId> {
        let mut first = INVALID_PAGE_ID;
        let mut prev: Option<PageId> = None;
        for chunk in tail.chunks(OVERFLOW_PAYLOAD) {
            let id = match self.alloc_page() {
                Ok(id) => id,
                Err(e) => {
                    if let Some(p) = prev {
                        self.pool.unpin(p, true);
                    }
                    return Err(e);
                }
            };
            let page = self.pool.page_mut(id);
            format_plain(page, KIND_OVERFLOW, INVALID_PAGE_ID);
            page[PLAIN_HEADER..PLAIN_HEADER + chunk.len()].copy_from_slice(chunk);
            match prev {
                Some(p) => {
                    put_u32(self.pool.page_mut(p), 0, id);
                    self.pool.unpin(p, true);
                }
                None => first = id,
            }
            prev = Some(id);
            self.stats.overflow_pages_written += 1;
        }
        if let Some(p) = prev {
            self.pool.unpin(p, true);
        }
        Ok(first)
    }

    /// Fill `out` from the chain that starts at `first`: the part of a value
    /// that is not in its leaf. One page pinned at a time.
    fn read_chain(&mut self, first: PageId, out: &mut [u8]) -> Result<()> {
        let mut id = first;
        for chunk in out.chunks_mut(OVERFLOW_PAYLOAD) {
            pin_plain(&mut self.pool, id, KIND_OVERFLOW)?;
            let page = self.pool.page(id);
            chunk.copy_from_slice(&page[PLAIN_HEADER..PLAIN_HEADER + chunk.len()]);
            let next = plain_next(page);
            self.pool.unpin(id, false);
            id = next;
        }
        // The chain must end exactly where the stored length says.
        if id != INVALID_PAGE_ID {
            return Err(TreeError::Corrupt);
        }
        Ok(())
    }

    /// Give the `pages` pages of the chain starting at `first` to the free
    /// list. Each page is read for its link before it is freed.
    fn free_chain(&mut self, first: PageId, pages: usize) -> Result<()> {
        let mut id = first;
        for _ in 0..pages {
            pin_plain(&mut self.pool, id, KIND_OVERFLOW)?;
            let next = plain_next(self.pool.page(id));
            self.pool.unpin(id, false);
            self.free_page(id)?;
            id = next;
        }
        if id != INVALID_PAGE_ID {
            return Err(TreeError::Corrupt);
        }
        Ok(())
    }

    // ---- get ----------------------------------------------------------------

    /// The value stored under `key`, as an owned `Vec`, or None.
    pub fn get(&mut self, key: &[u8]) -> Result<Option<Vec<u8>>> {
        let mut buf = ValueBuf::new();
        Ok(self.get_into(key, &mut buf)?.then(|| buf.into_vec()))
    }

    /// Assemble the value stored under `key` in `out`; false if there is no
    /// such key. With a `ValueBuf` on the caller's stack, a value that was
    /// stored whole in its leaf never touches the heap (see demo.rs, part 4).
    pub fn get_into(&mut self, key: &[u8], out: &mut ValueBuf) -> Result<bool> {
        if self.poisoned {
            return Err(TreeError::TreePoisoned);
        }
        let leaf_id = self.find_leaf(key, false)?;
        let leaf = pin_node(&mut self.pool, &mut self.checked, leaf_id)?;
        let started = leaf.get(key).map(|field| start_value(out, field));
        self.pool.unpin(leaf_id, false);
        let Some(started) = started else {
            return Ok(false);
        };
        let (filled, first) = started?;
        self.read_chain(first, &mut out.as_mut_slice()[filled..])?;
        Ok(true)
    }

    /// Walk from the root to the leaf that owns `key`, one pin at a time: a
    /// parent is unpinned before its child is fetched, which is fine without
    /// concurrency (chapter 19 is about when it is not). With `record_path`,
    /// `self.path` receives the interior pages passed and the child index
    /// taken in each. Returns the leaf's page id, not pinned.
    fn find_leaf(&mut self, key: &[u8], record_path: bool) -> Result<PageId> {
        self.path.clear();
        let mut id = self.root;
        for _ in 0..MAX_HEIGHT {
            let page = pin_node(&mut self.pool, &mut self.checked, id)?;
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
        // Deeper than any tree: the child pointers lead in a circle.
        Err(TreeError::Corrupt)
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
        // The steps are each all-or-nothing, but not together. Once one has
        // changed a page, a failure in a later one leaves pages leaked or
        // the tree half-split. (Zig says this with one `errdefer`; here the
        // steps run in an inner function and the result is checked.)
        self.changed = false;
        let result = self.put_steps(key, value);
        if result.is_err() && self.changed {
            self.poisoned = true;
        }
        result
    }

    fn put_steps(&mut self, key: &[u8], value: &[u8]) -> Result<()> {
        let leaf_id = self.find_leaf(key, true)?;
        // 1. What is stored under the key now? An old chain is freed at the
        //    very end, when no cell points at it any more.
        let old = {
            let leaf = pin_node(&mut self.pool, &mut self.checked, leaf_id)?;
            let old = leaf
                .get(key)
                .map(|field| parse_field(field).map(|r| (r.first, overflow_pages(r.total))));
            self.pool.unpin(leaf_id, false);
            old.transpose()?
        };
        // (the metapage's counter is a number from the file like any other)
        if old.is_none() && self.key_count == u64::MAX {
            return Err(TreeError::Corrupt);
        }
        // 2. The new value field; a large value gets its chain here.
        let field = self.write_value(value)?;
        // 3. The leaf cell. To the tree the field is just a value of at
        //    most 1096 bytes, so the split code of chapter 12 is unchanged.
        let mut leaf = pin_node(&mut self.pool, &mut self.checked, leaf_id)?;
        match leaf.put(key, &field) {
            Ok(()) => {
                self.pool.unpin(leaf_id, true);
                self.changed = true;
            }
            Err(PageError::CellTooLarge) => unreachable!("excluded by the length checks"),
            Err(PageError::PageFull) => {
                self.pool.unpin(leaf_id, false);
                self.split_and_insert(leaf_id, key, &field)?;
            }
        }
        // 4. The old chain, if the old value had one.
        match old {
            Some((first, pages)) => self.free_chain(first, pages)?,
            None => self.key_count += 1,
        }
        Ok(())
    }

    /// The leaf `leaf_id` has no room for (key, value). Split it, then hand
    /// the separator to the parent; if the parent has no room either, split
    /// that too, and so on up the remembered path. Splits therefore run
    /// bottom-up: only now, at the leaf, do we know that a split is needed
    /// and how many bytes the parent must take.
    fn split_and_insert(&mut self, leaf_id: PageId, key: &[u8], value: &[u8]) -> Result<()> {
        let mut id = leaf_id;
        if self.path.is_empty() {
            // The leaf is the root. The root never splits: its content
            // moves down first, and the page below it splits.
            id = self.push_root_down()?;
            self.path.push(PathEntry {
                id: self.root,
                index: 0,
            });
        }
        let mut carry = self.split_leaf(id, key, value)?;

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

    /// `alloc_page` for a caller that holds page `held` pinned: on failure
    /// that pin is released (Zig: `errdefer`).
    fn alloc_beside(&mut self, held: PageId) -> Result<PageId> {
        self.alloc_page()
            .inspect_err(|_| self.pool.unpin(held, false))
    }

    /// Grow the tree by one level WITHOUT changing the root's page id: copy
    /// the root page into a new page and turn the root into an interior page
    /// with no key and that new page as its only (rightmost) child. Returns
    /// the new page, which the caller then splits like any other page.
    fn push_root_down(&mut self) -> Result<PageId> {
        let root_id = self.root;
        self.pool.fetch_page(root_id)?;
        let child_id = self.alloc_beside(root_id)?;
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
    /// to a new page and is linked in after it.
    fn split_leaf(&mut self, id: PageId, key: &[u8], value: &[u8]) -> Result<Carry> {
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

        let right_id = self.alloc_beside(id)?; // the last step that can fail
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
    fn insert_separator(&mut self, parent: PathEntry, carry: &Carry) -> Result<bool> {
        let mut page = pin_node(&mut self.pool, &mut self.checked, parent.id)?;
        if page.kind() != KIND_INTERIOR
            || parent.index > page.count()
            || child_at(&page, parent.index) != carry.left
        {
            self.pool.unpin(parent.id, false);
            return Err(TreeError::Corrupt);
        }
        // In a sound tree the separator sorts between its new neighbours
        // (T3). `insert_at` asserts it, and so does the split of this page.
        let sep = carry.sep.as_slice();
        if (parent.index > 0 && page.key(parent.index - 1) >= sep)
            || (parent.index < page.count() && sep >= page.key(parent.index))
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
    /// it separates the two halves and is needed in neither.
    fn split_interior(&mut self, parent: PathEntry, carry: &Carry) -> Result<Carry> {
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

        let right_id = self.alloc_beside(id)?; // the last step that can fail
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

    // ---- delete -------------------------------------------------------------

    /// Remove `key`. Returns false if it was not there.
    ///
    /// "Free at empty": a leaf is given back only when its LAST cell goes.
    /// Pages that are merely less than half full are left alone; nothing is
    /// merged and nothing is borrowed from a sibling (the README says why).
    pub fn delete(&mut self, key: &[u8]) -> Result<bool> {
        if self.poisoned {
            return Err(TreeError::TreePoisoned);
        }
        if key.len() > MAX_KEY_LEN {
            return Ok(false);
        }
        self.changed = false;
        let result = self.delete_steps(key);
        if result.is_err() && self.changed {
            self.poisoned = true;
        }
        result
    }

    fn delete_steps(&mut self, key: &[u8]) -> Result<bool> {
        let leaf_id = self.find_leaf(key, true)?;
        let mut leaf = pin_node(&mut self.pool, &mut self.checked, leaf_id)?;
        let r = leaf.search(key);
        if !r.found {
            self.pool.unpin(leaf_id, false);
            return Ok(false);
        }
        let (old_first, old_pages) = match parse_field(leaf.value(r.index)) {
            Ok(old) => (old.first, overflow_pages(old.total)),
            Err(e) => {
                self.pool.unpin(leaf_id, false);
                return Err(e);
            }
        };
        if self.key_count == 0 {
            // A key in a tree that the metapage says is empty.
            self.pool.unpin(leaf_id, false);
            return Err(TreeError::Corrupt);
        }
        let next = link(&leaf);
        if leaf.count() > 1 || self.path.is_empty() {
            // The common case: one page changed. (The root may become an
            // empty leaf; it is the one page that is never freed.)
            leaf.delete_at(r.index);
            self.pool.unpin(leaf_id, true);
            self.changed = true;
        } else {
            // The leaf's last cell: the whole page leaves the tree. Its
            // bytes are not touched, not even to remove the cell.
            self.pool.unpin(leaf_id, false);
            self.remove_leaf(leaf_id, next)?;
        }
        self.free_chain(old_first, old_pages)?;
        self.key_count -= 1;
        Ok(true)
    }

    /// Take the leaf at the end of `self.path` out of the tree and free it.
    ///
    ///   1. the leaf chain: the left sibling's link skips the leaf
    ///   2. the parent: the pointer to the leaf goes, and one separator with
    ///      it. A parent that had no other child goes too, and so on up; a
    ///      root that loses its only child becomes an empty leaf again
    ///   3. only now are the removed pages freed (nothing points at them)
    ///   4. a root left with a single child takes that child's place
    fn remove_leaf(&mut self, leaf_id: PageId, next: PageId) -> Result<()> {
        if let Some(left_id) = self.left_sibling()? {
            let mut left = pin_node(&mut self.pool, &mut self.checked, left_id)?;
            if left.kind() != KIND_LEAF || link(&left) != leaf_id {
                self.pool.unpin(left_id, false);
                return Err(TreeError::Corrupt);
            }
            set_link(&mut left, next);
            self.pool.unpin(left_id, true);
            self.changed = true;
        }

        let mut doomed = vec![leaf_id];
        let mut level = self.path.len();
        loop {
            level -= 1;
            let entry = self.path[level];
            let mut page = pin_node(&mut self.pool, &mut self.checked, entry.id)?;
            let n = page.count();
            if page.kind() != KIND_INTERIOR
                || entry.index > n
                || child_at(&page, entry.index) != doomed[doomed.len() - 1]
            {
                self.pool.unpin(entry.id, false);
                return Err(TreeError::Corrupt);
            }
            if n > 0 {
                // Children C_0 .. C_n with separators K_0 .. K_(n-1); C_i
                // goes. If it has a right neighbour, cell i = (K_i -> C_i)
                // goes and C_(i+1) inherits the keys from K_(i-1) on. The
                // rightmost child has no cell: its left neighbour becomes
                // the rightmost child and cell n-1 goes instead. Either
                // way one separator disappears and no key moves.
                if entry.index == n {
                    let new_rightmost = child_at(&page, n - 1);
                    set_link(&mut page, new_rightmost);
                    page.delete_at(n - 1);
                } else {
                    page.delete_at(entry.index);
                }
                self.pool.unpin(entry.id, true);
                self.changed = true;
                break;
            }
            if level == 0 {
                // The root lost its only child: the tree is empty.
                let mut root =
                    SlottedPage::init_reserved(self.pool.page_mut(entry.id), RESERVED_TAIL);
                root.set_kind(KIND_LEAF);
                set_link(&mut root, INVALID_PAGE_ID);
                self.pool.unpin(entry.id, true);
                self.changed = true;
                break;
            }
            // An interior page whose only child goes is empty too.
            self.pool.unpin(entry.id, false);
            doomed.push(entry.id);
        }
        for &id in &doomed {
            self.free_page(id)?;
        }
        self.stats.tree_pages_freed += doomed.len() as u64;
        self.stats.interior_pages_freed += doomed.len() as u64 - 1;
        self.collapse_root()
    }

    /// The leaf just before the leaf at the end of `self.path`, or None if
    /// that is the first leaf. Leaves are singly linked (the page header has
    /// room for one id), so the left sibling is found from above: go up to
    /// the nearest ancestor where the path did not take child 0, step one
    /// child to the left, then keep right down to a leaf.
    fn left_sibling(&mut self) -> Result<Option<PageId>> {
        let Some(&turn) = self.path.iter().rev().find(|entry| entry.index > 0) else {
            return Ok(None);
        };
        let mut id = {
            let page = pin_node(&mut self.pool, &mut self.checked, turn.id)?;
            let child = (page.kind() == KIND_INTERIOR && turn.index <= page.count())
                .then(|| child_at(&page, turn.index - 1));
            self.pool.unpin(turn.id, false);
            child.ok_or(TreeError::Corrupt)?
        };
        for _ in 0..MAX_HEIGHT {
            let page = pin_node(&mut self.pool, &mut self.checked, id)?;
            let is_leaf = page.kind() == KIND_LEAF;
            let rightmost = link(&page);
            self.pool.unpin(id, false);
            if is_leaf {
                return Ok(Some(id));
            }
            id = rightmost;
        }
        Err(TreeError::Corrupt)
    }

    /// While the root is an interior page with no key, its single child
    /// holds the whole tree: copy the child into the root page and free the
    /// child. This is `push_root_down` backwards, and like it keeps the
    /// root's page id. Only the root is collapsed; a single-child page
    /// further down stays (exercise 4).
    fn collapse_root(&mut self) -> Result<()> {
        for _ in 0..MAX_HEIGHT {
            let root_id = self.root;
            let root = pin_node(&mut self.pool, &mut self.checked, root_id)?;
            if root.kind() != KIND_INTERIOR || root.count() != 0 {
                self.pool.unpin(root_id, false);
                return Ok(());
            }
            let child_id = link(&root);
            if child_id == root_id {
                self.pool.unpin(root_id, false);
                return Err(TreeError::Corrupt);
            }
            if let Err(e) = pin_node(&mut self.pool, &mut self.checked, child_id) {
                self.pool.unpin(root_id, false);
                return Err(e);
            }
            let (root_buf, child_buf) = self.pool.page_pair_mut(root_id, child_id);
            *root_buf = *child_buf;
            let was_interior = root_buf[OFF_KIND] == KIND_INTERIOR;
            self.pool.unpin(child_id, false);
            self.pool.unpin(root_id, true);
            self.changed = true;
            self.free_page(child_id)?;
            self.stats.tree_pages_freed += 1;
            self.stats.interior_pages_freed += u64::from(was_interior);
            self.stats.root_collapses += 1;
        }
        Err(TreeError::Corrupt)
    }

    // ---- range --------------------------------------------------------------

    /// Iterate over the entries with lo <= key < hi in key order; `hi` None
    /// means "to the end". `lo` = b"" starts at the first key.
    pub fn range(&mut self, lo: &[u8], hi: Option<&[u8]>) -> Result<RangeIterator<'_>> {
        if self.poisoned {
            return Err(TreeError::TreePoisoned);
        }
        let leaf_id = self.find_leaf(lo, false)?;
        let slot = pin_node(&mut self.pool, &mut self.checked, leaf_id)?
            .search(lo)
            .index;
        self.pool.unpin(leaf_id, false);
        Ok(RangeIterator {
            tree: self,
            leaf: leaf_id,
            slot,
            hi: hi.map(<[u8]>::to_vec),
            hops: 0,
            key: Vec::new(),
            value: ValueBuf::new(),
        })
    }

    // ---- validate -------------------------------------------------------------

    /// Check invariants T1 to T10 (see the top of the file) by reading every
    /// page of the file.
    pub fn validate(&mut self) -> Result<()> {
        self.page_map().map(|_| ())
    }

    /// `validate`, returning the role it found for every page: the file's
    /// page map.
    pub fn page_map(&mut self) -> Result<Vec<Role>> {
        let mut walk = Walk {
            roles: vec![Role::Unseen; self.pool.pager().page_count() as usize],
            leaves: Vec::new(),
            leaf_depth: None,
            keys: 0,
        };
        walk.roles[META_PAGE_ID as usize] = Role::Meta;
        self.visit(&mut walk, self.root, None, None, 0)?;

        for (i, &(_, next)) in walk.leaves.iter().enumerate() {
            let expected = walk
                .leaves
                .get(i + 1)
                .map_or(INVALID_PAGE_ID, |&(id, _)| id);
            if next != expected {
                return invalid(Violation::LeafChainBroken); // T5
            }
        }
        if walk.keys != self.key_count {
            return invalid(Violation::KeyCountMismatch); // T8
        }
        self.check_free_list(&mut walk)?; // T10
        if walk.roles.contains(&Role::Unseen) {
            return invalid(Violation::UnreachablePage); // T6
        }
        Ok(walk.roles)
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
        if id as usize >= walk.roles.len() {
            return invalid(Violation::BadPage);
        }
        if depth >= MAX_HEIGHT {
            return invalid(Violation::UnevenDepth); // T4
        }
        // Claimed as a leaf for now; corrected below.
        walk.claim(id, Role::Leaf)?;

        // Work on a copy, so that the recursion can run without a pin (the
        // pool may be tiny). The pin itself is kept until the page has been
        // checked: a leaf stays pinned while its chains are walked, exactly
        // as in the Zig twin.
        let mut copy: Page = *self.pool.fetch_page(id)?;
        let page = SlottedPage::open(&mut copy);
        let checked = self.check_page(walk, &page, id, lo, hi, depth);
        self.pool.unpin(id, false);
        if checked? == KIND_LEAF {
            return Ok(());
        }
        walk.roles[id as usize] = Role::Interior;
        let n = page.count();
        for i in 0..=n {
            let child_lo = if i == 0 { lo } else { Some(page.key(i - 1)) };
            let child_hi = if i == n { hi } else { Some(page.key(i)) };
            self.visit(walk, child_at(&page, i), child_lo, child_hi, depth + 1)?;
        }
        Ok(())
    }

    /// Everything `visit` checks about one page; for a leaf that includes
    /// the overflow chains of its values. Returns the page's kind.
    fn check_page(
        &mut self,
        walk: &mut Walk,
        page: &SlottedPage,
        id: PageId,
        lo: Option<&[u8]>,
        hi: Option<&[u8]>,
        depth: usize,
    ) -> Result<u8> {
        // `node_is_sound` is safe on any bytes; everything after it may
        // trust the page. Checked here every time: `validate` is also for
        // pages this handle has changed.
        if !node_is_sound(page) {
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
            walk.leaves.push((id, link(page)));
            for i in 0..n {
                let Ok(value) = parse_field(page.value(i)) else {
                    return invalid(Violation::BadCell); // T9
                };
                self.check_chain(walk, value)?;
            }
            return Ok(KIND_LEAF);
        }
        if n == 0 && id == self.root {
            return invalid(Violation::EmptyPage); // T7
        }
        Ok(KIND_INTERIOR)
    }

    /// T9: the chain of one value has exactly the pages its length asks
    /// for, each an overflow page that no other cell uses.
    fn check_chain(&mut self, walk: &mut Walk, value: ValueRef) -> Result<()> {
        let mut id = value.first;
        for _ in 0..overflow_pages(value.total) {
            if id as usize >= walk.roles.len() {
                return invalid(Violation::OverflowChainBroken); // includes "ended early"
            }
            walk.claim(id, Role::Overflow)?;
            let page = self.pool.fetch_page(id)?;
            let kind = page[OFF_KIND];
            let next = plain_next(page);
            self.pool.unpin(id, false);
            if kind != KIND_OVERFLOW {
                return invalid(Violation::OverflowChainBroken);
            }
            id = next;
        }
        if id != INVALID_PAGE_ID {
            return invalid(Violation::OverflowChainBroken);
        }
        Ok(())
    }

    /// T10. A loop in the list is caught by `claim`.
    fn check_free_list(&mut self, walk: &mut Walk) -> Result<()> {
        let mut listed: u64 = 0;
        let mut id = self.free_head;
        while id != INVALID_PAGE_ID {
            if id as usize >= walk.roles.len() {
                return invalid(Violation::FreeListBroken);
            }
            walk.claim(id, Role::Trunk)?;
            let trunk: Page = *self.pool.fetch_page(id)?;
            self.pool.unpin(id, false);
            let n = trunk_count(&trunk);
            if trunk[OFF_KIND] != KIND_TRUNK || n > TRUNK_CAPACITY {
                return invalid(Violation::FreeListBroken);
            }
            for i in 0..n {
                let free = u32_at(&trunk, trunk_entry(i));
                if free as usize >= walk.roles.len() {
                    return invalid(Violation::FreeListBroken);
                }
                walk.claim(free, Role::Free)?;
            }
            listed += 1 + n as u64;
            id = plain_next(&trunk);
        }
        if listed != u64::from(self.free_count) {
            return invalid(Violation::FreeListBroken);
        }
        Ok(())
    }

    // ---- inspection -------------------------------------------------------------

    /// Number of levels: 1 for a root that is a leaf.
    pub fn height(&mut self) -> Result<u32> {
        let mut id = self.root;
        for levels in 1..=MAX_HEIGHT as u32 {
            let page = pin_node(&mut self.pool, &mut self.checked, id)?;
            let child = (page.kind() != KIND_LEAF).then(|| child_at(&page, 0));
            self.pool.unpin(id, false);
            match child {
                Some(child) => id = child,
                None => return Ok(levels),
            }
        }
        Err(TreeError::Corrupt)
    }

    /// The tree as text, one page per line, children indented under their
    /// parent, then the free list. Keys are printed as text, with every
    /// byte that is not printable ASCII as `\xNN` (keys are arbitrary bytes,
    /// and Zig and Rust must print the same). A value is printed as its length; a value with a chain as
    /// `total=local+[overflow page ids]`. (Zig prints to a writer.)
    ///
    /// Bounded on a damaged file: the tree part prints at most as many pages
    /// as the file has and stops with `Corrupt` after that, the free list
    /// part prints at most that many trunks and then says that it loops.
    pub fn dump(&mut self) -> Result<String> {
        use std::fmt::Write;
        let mut out = String::new();
        let pages = self.pool.pager().page_count() as usize;
        let mut budget = pages;
        self.dump_page(&mut out, self.root, 0, &mut budget)?;
        // Writing to a String cannot fail.
        let _ = write!(out, "free list: {} pages", self.free_count);
        let mut id = self.free_head;
        let mut trunks = 0;
        while id != INVALID_PAGE_ID {
            if trunks == pages {
                out.push_str(" | ... (the list loops)");
                break;
            }
            trunks += 1;
            pin_plain(&mut self.pool, id, KIND_TRUNK)?;
            let trunk = self.pool.page(id);
            let _ = write!(out, " | trunk {id}:");
            for i in 0..trunk_count(trunk).min(TRUNK_CAPACITY) {
                let _ = write!(out, " {}", u32_at(trunk, trunk_entry(i)));
            }
            let next = plain_next(trunk);
            self.pool.unpin(id, false);
            id = next;
        }
        out.push('\n');
        Ok(out)
    }

    fn dump_page(
        &mut self,
        out: &mut String,
        id: PageId,
        depth: usize,
        budget: &mut usize,
    ) -> Result<()> {
        use std::fmt::Write;
        // A page reached twice is printed twice, so a loop among the child
        // pointers would print for ever without these two bounds.
        if depth >= MAX_HEIGHT || *budget == 0 {
            return Err(TreeError::Corrupt);
        }
        *budget -= 1;
        // A copy, so that a leaf's chains can be followed while it stays
        // pinned (Zig reads the pinned frame directly).
        let mut copy: Page = *pin_node(&mut self.pool, &mut self.checked, id)?.bytes();
        let page = SlottedPage::open(&mut copy);
        let n = page.count();
        let used = PAGE_CAPACITY - page.free_bytes();
        out.push_str(&"  ".repeat(depth));
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
            let cells = self.dump_cells(out, &page);
            self.pool.unpin(id, false);
            cells?;
            out.push('\n');
            return Ok(());
        }
        let _ = write!(
            out,
            "page {id}  interior  {n} keys  {used}/{PAGE_CAPACITY} bytes  |"
        );
        let children: Vec<PageId> = (0..=n).map(|i| child_at(&page, i)).collect();
        for (i, child) in children.iter().enumerate() {
            if i < n {
                let _ = write!(out, " ({child}) {}", escape_key(page.key(i)));
            } else {
                let _ = writeln!(out, " ({child})");
            }
        }
        self.pool.unpin(id, false);
        for child in children {
            self.dump_page(out, child, depth + 1, budget)?;
        }
        Ok(())
    }

    fn dump_cells(&mut self, out: &mut String, page: &SlottedPage) -> Result<()> {
        use std::fmt::Write;
        for i in 0..page.count() {
            let value = parse_field(page.value(i))?;
            let _ = write!(out, " {}:{}", escape_key(page.key(i)), value.total);
            if value.first == INVALID_PAGE_ID {
                continue;
            }
            let _ = write!(out, "={}+[", value.local.len());
            let mut at = value.first;
            for j in 0..overflow_pages(value.total) {
                let _ = write!(out, "{}{at}", if j == 0 { "" } else { " " });
                pin_plain(&mut self.pool, at, KIND_OVERFLOW)?;
                let next = plain_next(self.pool.page(at));
                self.pool.unpin(at, false);
                at = next;
            }
            out.push(']');
        }
        Ok(())
    }
}

/// What `validate` collects on its way through the file.
struct Walk {
    roles: Vec<Role>,
    /// The leaves in the order the tree reaches them: (id, link).
    leaves: Vec<(PageId, PageId)>,
    leaf_depth: Option<usize>,
    keys: u64,
}

impl Walk {
    /// Give page `id` its role; it must not have one yet (T6).
    fn claim(&mut self, id: PageId, role: Role) -> Result<()> {
        let old = self.roles[id as usize];
        if old != Role::Unseen {
            return invalid(if old.family() == role.family() {
                Violation::PageReachedTwice
            } else {
                Violation::PageInTwoRoles
            });
        }
        self.roles[id as usize] = role;
        Ok(())
    }
}

/// A position in the leaf level: (leaf page id, slot). It holds no pin
/// between calls; each `next` pins the leaf, copies one entry out and unpins.
///
/// Where the value goes: a `ValueBuf` inside the iterator, so a value that
/// was stored whole in its leaf is copied into the iterator itself (on its
/// caller's stack), and only a value with an overflow chain uses the heap.
///
/// Difference from Zig: the iterator borrows the tree mutably, so the rule
/// "do not modify the tree while an iterator is in use" is checked by the
/// compiler here and is only a comment there; and there is no `deinit`,
/// dropping the iterator frees its buffers.
pub struct RangeIterator<'a> {
    tree: &'a mut DiskBTree,
    leaf: PageId,
    slot: usize,
    hi: Option<Vec<u8>>,
    /// Sibling links followed so far. A scan that follows more links than
    /// the file has pages is going round in a circle.
    hops: usize,
    key: Vec<u8>,
    value: ValueBuf,
}

impl RangeIterator<'_> {
    /// The next entry, or None at the end. The slices are valid until the
    /// next call, which is why this cannot be `std::iter::Iterator`: its
    /// items may not borrow from the iterator.
    #[allow(clippy::should_implement_trait)]
    pub fn next(&mut self) -> Result<Option<(&[u8], &[u8])>> {
        self.value.clear();
        while self.leaf != INVALID_PAGE_ID {
            let DiskBTree { pool, checked, .. } = &mut *self.tree;
            let pinned = self.leaf; // `self.leaf` may move on below
            let page = pin_node(pool, checked, pinned)?;
            if page.kind() != KIND_LEAF {
                pool.unpin(pinned, false);
                return Err(TreeError::Corrupt);
            }
            if self.slot >= page.count() {
                // End of this leaf: follow the sibling link. No parent is
                // needed, which is the point of chaining the leaves.
                self.leaf = link(&page);
                self.slot = 0;
                pool.unpin(pinned, false);
                self.hops += 1;
                if self.hops > pool.pager().page_count() as usize {
                    return Err(TreeError::Corrupt);
                }
                continue;
            }
            let key = page.key(self.slot);
            if self.hi.as_deref().is_some_and(|hi| key >= hi) {
                self.leaf = INVALID_PAGE_ID;
                pool.unpin(pinned, false);
                return Ok(None);
            }
            self.key.clear();
            self.key.extend_from_slice(key);
            let started = start_value(&mut self.value, page.value(self.slot));
            pool.unpin(pinned, false);
            let (filled, first) = started.inspect_err(|_| self.value.clear())?;
            if let Err(e) = self
                .tree
                .read_chain(first, &mut self.value.as_mut_slice()[filled..])
            {
                self.value.clear();
                return Err(e);
            }
            self.slot += 1;
            return Ok(Some((&self.key, self.value.as_slice())));
        }
        Ok(None)
    }

    /// True if the current value did not fit the inline buffer.
    pub fn value_on_heap(&self) -> bool {
        self.value.on_heap()
    }
}
