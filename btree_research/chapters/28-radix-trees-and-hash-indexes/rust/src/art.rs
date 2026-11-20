//! Adaptive radix tree (ART): insert, search, ordered iteration. No delete.
//!
//! Shape of the tree (the same choices DuckDB makes, see the chapter README):
//!
//!   * An INNER node consumes exactly one key byte and maps it to a child. It
//!     comes in four layouts, Node4 / Node16 / Node48 / Node256, picked by the
//!     number of children. A full node is copied into the next larger layout.
//!   * A PREFIX node holds 1..7 key bytes that every key below it shares, and
//!     one child. This is path compression: a run of one-child levels costs
//!     one node instead of one node per byte.
//!   * A LEAF is not a node at all: the value is stored inside the reference
//!     that would otherwise point to a node. The key is not stored anywhere in
//!     one piece; it is spelled out by the path from the root.
//!
//! Requirement on keys: non-empty, and no key is a strict prefix of another
//! (see keys.rs). Otherwise a value would have to live in the middle of a
//! path, and this tree has no place for it. `put` reports `ArtError::PrefixKey`.
//!
//! Zig twin: ../zig/src/art.zig. Where Zig holds `*Node4` pointers into five
//! `MemoryPool`s, this version holds `u32` indices into five `Slab`s.
use crate::keys::{self, Entry, Lookup};
use std::cmp::Ordering;
use std::fmt::Write;

/// Bytes per prefix node. DuckDB derives this from the key type and gets 7
/// for a single 8-byte integer key (art.cpp:1258-1287).
pub const PREFIX_CAP: usize = 7;

/// Longest key `put` accepts, in bytes. The limit exists because of how this
/// teaching version walks the tree: `insert_at`, `census`, `validate` and
/// `dump` recurse once per node, and a path has at most one node per key
/// byte. So the key length bounds the recursion depth, and with it the stack
/// those walks need (512 levels fit comfortably in the default stacks of
/// both languages, see the test `the_longest_keys`). Without a limit a key
/// of some tens of thousands of bytes overflows the stack. `lookup` and the
/// iterator are loops and would not need the limit.
pub const MAX_KEY_LEN: usize = 512;

/// A reference to a subtree. Leaves are inlined: `Leaf` carries the value.
/// The `u32` is an index into the slab of that node type.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Ref {
    None,
    Leaf(u64),
    Prefix(u32),
    N4(u32),
    N16(u32),
    N48(u32),
    N256(u32),
}

#[derive(Debug, Clone, Copy)]
pub struct Prefix {
    len: u8,
    bytes: [u8; PREFIX_CAP],
    child: Ref,
}

impl Prefix {
    fn slice(&self) -> &[u8] {
        &self.bytes[..self.len as usize]
    }
}

/// Node4 and Node16 are the same layout with a different capacity: the key
/// bytes are kept SORTED in `keys[..count]` and `children[i]` belongs to
/// `keys[i]`. Sorted order is what makes in-order iteration a left-to-right
/// walk. Finding a byte is a plain linear scan (DuckDB does the same, with no
/// SIMD: base_node.hpp:72-82).
#[derive(Debug, Clone)]
pub struct SmallNode<const CAP: usize> {
    count: u8,
    keys: [u8; CAP],
    children: [Ref; CAP],
}

impl<const CAP: usize> SmallNode<CAP> {
    fn new() -> Self {
        SmallNode { count: 0, keys: [0; CAP], children: [Ref::None; CAP] }
    }

    fn find(&self, byte: u8) -> Option<usize> {
        self.keys[..self.count as usize].iter().position(|&k| k == byte)
    }

    /// Insert keeping `keys` sorted. Caller guarantees room and absence.
    fn add(&mut self, byte: u8, child: Ref) {
        assert!((self.count as usize) < CAP);
        let mut i = self.count as usize;
        while i > 0 && self.keys[i - 1] > byte {
            self.keys[i] = self.keys[i - 1];
            self.children[i] = self.children[i - 1];
            i -= 1;
        }
        self.keys[i] = byte;
        self.children[i] = child;
        self.count += 1;
    }

    /// First child whose byte is >= `from`.
    fn next_child(&self, from: u16) -> Option<(u8, Ref)> {
        let n = self.count as usize;
        (0..n).find(|&i| u16::from(self.keys[i]) >= from).map(|i| (self.keys[i], self.children[i]))
    }
}

pub type Node4 = SmallNode<4>;
pub type Node16 = SmallNode<16>;

/// Node48: a 256-entry byte table that maps a key byte to a position in a
/// 48-entry child array. Two array reads, no scan. `EMPTY48` marks "no child".
#[derive(Debug, Clone)]
pub struct Node48 {
    count: u8,
    index: [u8; 256],
    children: [Ref; 48],
}

const EMPTY48: u8 = 48;

/// Node256: the child array is indexed by the key byte directly.
#[derive(Debug, Clone)]
pub struct Node256 {
    count: u16,
    children: [Ref; 256],
}

/// The five allocation size classes. Leaves are inlined and need none.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Kind {
    Prefix = 0,
    Node4 = 1,
    Node16 = 2,
    Node48 = 3,
    Node256 = 4,
}

pub const KIND_COUNT: usize = 5;
pub const KIND_NAMES: [&str; KIND_COUNT] = ["prefix", "node4", "node16", "node48", "node256"];
/// Child slots of each inner layout (a prefix node has one fixed child).
pub const KIND_SLOTS: [usize; KIND_COUNT] = [1, 4, 16, 48, 256];

/// One size class: a `Vec` of nodes of one type plus a free list of indices.
/// This is the Rust idiom for Zig's `std.heap.MemoryPool(T)`: a freed slot is
/// pushed on `free` and handed out again by the next `alloc`.
#[derive(Debug)]
struct Slab<T> {
    items: Vec<T>,
    free: Vec<u32>,
}

impl<T> Slab<T> {
    fn new() -> Self {
        Slab { items: Vec::new(), free: Vec::new() }
    }

    fn alloc(&mut self, node: T) -> u32 {
        if let Some(id) = self.free.pop() {
            self.items[id as usize] = node;
            id
        } else {
            self.items.push(node);
            (self.items.len() - 1) as u32
        }
    }

    fn release(&mut self, id: u32) {
        // The stale node stays in `items` until the slot is reused; nothing
        // refers to it any more.
        self.free.push(id);
    }
}

/// The five slabs plus the counters the Zig version keeps next to its pools.
#[derive(Debug)]
struct Pools {
    prefix: Slab<Prefix>,
    n4: Slab<Node4>,
    n16: Slab<Node16>,
    n48: Slab<Node48>,
    n256: Slab<Node256>,
    /// Nodes currently in use, per size class.
    live: [usize; KIND_COUNT],
    /// Nodes ever handed out, per size class (reuse included).
    created: [usize; KIND_COUNT],
    /// Stand-in for allocation failure: at most this many live nodes.
    max_nodes: usize,
}

impl Pools {
    /// Called before every allocation. Zig gets `error.OutOfMemory` from the
    /// allocator; here the budget plays that role.
    fn reserve(&mut self, kind: Kind) -> Result<(), ArtError> {
        if self.live.iter().sum::<usize>() >= self.max_nodes {
            return Err(ArtError::OutOfNodes);
        }
        self.live[kind as usize] += 1;
        self.created[kind as usize] += 1;
        Ok(())
    }

    fn new_prefix(&mut self, node: Prefix) -> Result<u32, ArtError> {
        self.reserve(Kind::Prefix)?;
        Ok(self.prefix.alloc(node))
    }

    fn free_prefix(&mut self, id: u32) {
        self.prefix.release(id);
        self.live[Kind::Prefix as usize] -= 1;
    }
}

/// What the tree is made of, found by walking it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct Census {
    /// Reachable nodes per size class.
    pub nodes: [usize; KIND_COUNT],
    pub leaves: usize,
    /// Child slots in use / reserved, over the four inner layouts.
    pub slots_used: usize,
    pub slots_allocated: usize,
    /// Most nodes (prefix + inner) on any root-to-leaf path.
    pub max_path: usize,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ArtError {
    /// The node budget is exhausted (the twin of Zig's `error.OutOfMemory`).
    OutOfNodes,
    EmptyKey,
    /// The key is longer than `MAX_KEY_LEN`.
    KeyTooLong,
    PrefixKey,
}

impl std::fmt::Display for ArtError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(match self {
            ArtError::OutOfNodes => "node budget exhausted",
            ArtError::EmptyKey => "empty key",
            ArtError::KeyTooLong => "key is longer than MAX_KEY_LEN",
            ArtError::PrefixKey => "key is a prefix of a stored key, or the other way round",
        })
    }
}

impl std::error::Error for ArtError {}

#[derive(Debug)]
pub struct Art {
    root: Ref,
    len: usize,
    pools: Pools,
    /// grows[0] = Node4 to Node16, [1] = Node16 to Node48, [2] = Node48 to Node256.
    pub grows: [usize; 3],
    /// Number of prefix nodes that had to be split by an insert.
    pub prefix_splits: usize,
}

impl Default for Art {
    fn default() -> Self {
        Self::new()
    }
}

impl Art {
    pub fn new() -> Self {
        Self::with_node_budget(usize::MAX)
    }

    /// A tree that refuses to hold more than `max_nodes` nodes at a time.
    pub fn with_node_budget(max_nodes: usize) -> Self {
        Art {
            root: Ref::None,
            len: 0,
            pools: Pools {
                prefix: Slab::new(),
                n4: Slab::new(),
                n16: Slab::new(),
                n48: Slab::new(),
                n256: Slab::new(),
                live: [0; KIND_COUNT],
                created: [0; KIND_COUNT],
                max_nodes,
            },
            grows: [0; 3],
            prefix_splits: 0,
        }
    }

    pub fn len(&self) -> usize {
        self.len
    }

    pub fn is_empty(&self) -> bool {
        self.len == 0
    }

    /// Nodes currently in use, per size class.
    pub fn pool_live(&self) -> [usize; KIND_COUNT] {
        self.pools.live
    }

    /// Nodes ever handed out, per size class (reuse included).
    pub fn pool_created(&self) -> [usize; KIND_COUNT] {
        self.pools.created
    }

    pub fn get(&self, key: &[u8]) -> Option<u64> {
        self.lookup(key).value
    }

    /// Point lookup. `steps` counts nodes visited (prefix and inner nodes).
    /// Note what is absent: no comparison against a stored key, no binary
    /// search. The cost is bounded by the key length, not by `len`.
    pub fn lookup(&self, key: &[u8]) -> Lookup {
        let mut r = self.root;
        let mut depth = 0;
        let mut steps = 0;
        loop {
            match r {
                Ref::None => return Lookup { value: None, steps },
                // The whole path matched; it is our key only if it used all bytes.
                Ref::Leaf(v) => {
                    return Lookup { value: (depth == key.len()).then_some(v), steps };
                }
                Ref::Prefix(id) => {
                    steps += 1;
                    let p = &self.pools.prefix.items[id as usize];
                    if !key[depth..].starts_with(p.slice()) {
                        return Lookup { value: None, steps };
                    }
                    depth += p.len as usize;
                    r = p.child;
                }
                _ => {
                    steps += 1;
                    if depth == key.len() {
                        return Lookup { value: None, steps };
                    }
                    match self.child_of(r, key[depth]) {
                        Some(child) => r = child,
                        None => return Lookup { value: None, steps },
                    }
                    depth += 1;
                }
            }
        }
    }

    /// Insert or overwrite. Returns the previous value if the key existed.
    /// On any error the tree is exactly as it was before the call.
    pub fn put(&mut self, key: &[u8], value: u64) -> Result<Option<u64>, ArtError> {
        if key.is_empty() {
            return Err(ArtError::EmptyKey);
        }
        // Bounds the recursion depth of insert_at and of the inspection walks.
        if key.len() > MAX_KEY_LEN {
            return Err(ArtError::KeyTooLong);
        }
        let mut old = None;
        self.root = self.insert_at(self.root, key, 0, value, &mut old)?;
        if old.is_none() {
            self.len += 1;
        }
        Ok(old)
    }

    /// Insert below `r`, whose path has consumed `key[..depth]`. Returns the
    /// reference the parent must now store: usually `r` itself, but a node
    /// that grew or a prefix that was split has a new identity. This is how a
    /// structural change stays local: the parent only swaps one reference
    /// (compare DuckDB passing `NodePtr &node_ptr`, base_node.cpp:61-76).
    /// One recursion level per node on the path, at most `MAX_KEY_LEN` levels.
    fn insert_at(&mut self, r: Ref, key: &[u8], depth: usize, value: u64, old: &mut Option<u64>) -> Result<Ref, ArtError> {
        match r {
            // Only the empty root: the whole key becomes one prefix chain.
            Ref::None => self.new_chain(&key[depth..], value),
            Ref::Leaf(v) => {
                // A leaf ends a stored key. If our key continues, the stored
                // key is a strict prefix of ours.
                if depth != key.len() {
                    return Err(ArtError::PrefixKey);
                }
                *old = Some(v);
                Ok(Ref::Leaf(value))
            }
            Ref::Prefix(id) => {
                let p = self.pools.prefix.items[id as usize]; // a copy: 16 bytes
                for (i, &stored) in p.slice().iter().enumerate() {
                    // Our key ends inside the path: it is a prefix of stored keys.
                    if depth + i == key.len() {
                        return Err(ArtError::PrefixKey);
                    }
                    if stored != key[depth + i] {
                        return self.split_prefix(id, i, key, depth + i, value);
                    }
                }
                let child = self.insert_at(p.child, key, depth + p.len as usize, value, old)?;
                self.pools.prefix.items[id as usize].child = child;
                Ok(r)
            }
            _ => {
                if depth == key.len() {
                    return Err(ArtError::PrefixKey);
                }
                let byte = key[depth];
                if let Some(child) = self.child_of(r, byte) {
                    let new_child = self.insert_at(child, key, depth + 1, value, old)?;
                    self.set_child(r, byte, new_child);
                    return Ok(r);
                }
                // New branch. Allocate everything first, mutate last, so that
                // a failure leaves the tree untouched.
                let chain = self.new_chain(&key[depth + 1..], value)?;
                let node = if self.is_full(r) {
                    match self.grow(r) {
                        Ok(node) => node,
                        Err(e) => {
                            self.free_chain(chain); // Zig: errdefer
                            return Err(e);
                        }
                    }
                } else {
                    r
                };
                self.add_child(node, byte, chain);
                Ok(node)
            }
        }
    }

    /// Build `prefix -> prefix -> ... -> leaf` for the rest of a key. Built
    /// back to front so that every node is complete when it is linked.
    fn new_chain(&mut self, rest: &[u8], value: u64) -> Result<Ref, ArtError> {
        let mut child = Ref::Leaf(value);
        let mut end = rest.len();
        while end > 0 {
            let start = ((end - 1) / PREFIX_CAP) * PREFIX_CAP;
            let mut bytes = [0; PREFIX_CAP];
            bytes[..end - start].copy_from_slice(&rest[start..end]);
            match self.pools.new_prefix(Prefix { len: (end - start) as u8, bytes, child }) {
                Ok(id) => child = Ref::Prefix(id),
                Err(e) => {
                    self.free_chain(child); // Zig: errdefer
                    return Err(e);
                }
            }
            end = start;
        }
        Ok(child)
    }

    fn free_chain(&mut self, chain: Ref) {
        let mut r = chain;
        while let Ref::Prefix(id) = r {
            r = self.pools.prefix.items[id as usize].child;
            self.pools.free_prefix(id);
        }
    }

    /// The new key leaves prefix `id` at position `i` (key byte `key[at]`).
    ///
    /// ```text
    ///   before:  p[b0 .. bi .. bn] -> C
    ///   after:   p[b0 .. b(i-1)] -> Node4 { bi      -> rest[b(i+1) .. bn] -> C
    ///                                       key[at] -> new chain -> leaf }
    /// ```
    ///
    /// Either prefix piece may be empty and is then left out.
    fn split_prefix(&mut self, id: u32, i: usize, key: &[u8], at: usize, value: u64) -> Result<Ref, ArtError> {
        let chain = self.new_chain(&key[at + 1..], value)?;
        if let Err(e) = self.pools.reserve(Kind::Node4) {
            self.free_chain(chain);
            return Err(e);
        }
        let branch = self.pools.n4.alloc(Node4::new());

        let p = self.pools.prefix.items[id as usize];
        let old_byte = p.bytes[i];
        let rest_len = p.len as usize - i - 1;
        let mut old_side = p.child;
        if rest_len > 0 && i > 0 {
            // Both pieces are non-empty: the tail needs a node of its own.
            // This is the last allocation; nothing has been modified yet.
            let mut bytes = [0; PREFIX_CAP];
            bytes[..rest_len].copy_from_slice(&p.bytes[i + 1..p.len as usize]);
            match self.pools.new_prefix(Prefix { len: rest_len as u8, bytes, child: p.child }) {
                Ok(tail) => old_side = Ref::Prefix(tail),
                Err(e) => {
                    self.pools.n4.release(branch);
                    self.pools.live[Kind::Node4 as usize] -= 1;
                    self.free_chain(chain);
                    return Err(e);
                }
            }
        }

        // From here on nothing can fail.
        self.prefix_splits += 1;
        let mut result = Ref::N4(branch);
        let head = &mut self.pools.prefix.items[id as usize];
        if i > 0 {
            head.len = i as u8; // the old node keeps the shared head
            head.child = result;
            result = Ref::Prefix(id);
        } else if rest_len > 0 {
            // No shared head: reuse the old node itself as the tail.
            head.bytes.copy_within(1..1 + rest_len, 0);
            head.len = rest_len as u8;
            old_side = Ref::Prefix(id);
        } else {
            self.pools.free_prefix(id); // a 1-byte prefix dissolved into the branch
        }
        let node = &mut self.pools.n4.items[branch as usize];
        node.add(old_byte, old_side);
        node.add(key[at], chain);
        Ok(result)
    }

    /// Copy a full node into the next larger layout and free the old one.
    fn grow(&mut self, r: Ref) -> Result<Ref, ArtError> {
        match r {
            Ref::N4(id) => {
                self.pools.reserve(Kind::Node16)?;
                let old = &self.pools.n4.items[id as usize];
                let n = old.count as usize;
                let mut new = Node16::new();
                new.count = old.count;
                new.keys[..n].copy_from_slice(&old.keys[..n]);
                new.children[..n].copy_from_slice(&old.children[..n]);
                self.pools.n4.release(id);
                self.pools.live[Kind::Node4 as usize] -= 1;
                self.grows[0] += 1;
                Ok(Ref::N16(self.pools.n16.alloc(new)))
            }
            Ref::N16(id) => {
                self.pools.reserve(Kind::Node48)?;
                let old = &self.pools.n16.items[id as usize];
                let mut new = Node48 { count: old.count, index: [EMPTY48; 256], children: [Ref::None; 48] };
                for i in 0..old.count as usize {
                    new.index[old.keys[i] as usize] = i as u8;
                    new.children[i] = old.children[i];
                }
                self.pools.n16.release(id);
                self.pools.live[Kind::Node16 as usize] -= 1;
                self.grows[1] += 1;
                Ok(Ref::N48(self.pools.n48.alloc(new)))
            }
            Ref::N48(id) => {
                self.pools.reserve(Kind::Node256)?;
                let old = &self.pools.n48.items[id as usize];
                let mut new = Node256 { count: u16::from(old.count), children: [Ref::None; 256] };
                for (byte, &slot) in old.index.iter().enumerate() {
                    if slot != EMPTY48 {
                        new.children[byte] = old.children[slot as usize];
                    }
                }
                self.pools.n48.release(id);
                self.pools.live[Kind::Node48 as usize] -= 1;
                self.grows[2] += 1;
                Ok(Ref::N256(self.pools.n256.alloc(new)))
            }
            _ => unreachable!("only Node4, Node16 and Node48 can be full"),
        }
    }

    // ---- Operations that work on any of the four inner layouts ------------

    fn child_of(&self, r: Ref, byte: u8) -> Option<Ref> {
        match r {
            Ref::N4(id) => {
                let n = &self.pools.n4.items[id as usize];
                n.find(byte).map(|i| n.children[i])
            }
            Ref::N16(id) => {
                let n = &self.pools.n16.items[id as usize];
                n.find(byte).map(|i| n.children[i])
            }
            Ref::N48(id) => {
                let n = &self.pools.n48.items[id as usize];
                let slot = n.index[byte as usize];
                (slot != EMPTY48).then(|| n.children[slot as usize])
            }
            Ref::N256(id) => {
                let child = self.pools.n256.items[id as usize].children[byte as usize];
                (child != Ref::None).then_some(child)
            }
            _ => unreachable!("not an inner node"),
        }
    }

    /// Overwrite the child that already exists at `byte`.
    fn set_child(&mut self, r: Ref, byte: u8, child: Ref) {
        match r {
            Ref::N4(id) => {
                let n = &mut self.pools.n4.items[id as usize];
                let i = n.find(byte).expect("child exists");
                n.children[i] = child;
            }
            Ref::N16(id) => {
                let n = &mut self.pools.n16.items[id as usize];
                let i = n.find(byte).expect("child exists");
                n.children[i] = child;
            }
            Ref::N48(id) => {
                let n = &mut self.pools.n48.items[id as usize];
                n.children[n.index[byte as usize] as usize] = child;
            }
            Ref::N256(id) => self.pools.n256.items[id as usize].children[byte as usize] = child,
            _ => unreachable!("not an inner node"),
        }
    }

    fn is_full(&self, r: Ref) -> bool {
        match r {
            Ref::N4(id) => self.pools.n4.items[id as usize].count == 4,
            Ref::N16(id) => self.pools.n16.items[id as usize].count == 16,
            Ref::N48(id) => self.pools.n48.items[id as usize].count == 48,
            Ref::N256(_) => false, // one slot per possible byte: can never overflow
            _ => unreachable!("not an inner node"),
        }
    }

    /// Add a child at a byte that has none. Caller guarantees room.
    fn add_child(&mut self, r: Ref, byte: u8, child: Ref) {
        match r {
            Ref::N4(id) => self.pools.n4.items[id as usize].add(byte, child),
            Ref::N16(id) => self.pools.n16.items[id as usize].add(byte, child),
            Ref::N48(id) => {
                // Without delete there are no holes: the next free slot is `count`.
                let n = &mut self.pools.n48.items[id as usize];
                n.children[n.count as usize] = child;
                n.index[byte as usize] = n.count;
                n.count += 1;
            }
            Ref::N256(id) => {
                let n = &mut self.pools.n256.items[id as usize];
                n.children[byte as usize] = child;
                n.count += 1;
            }
            _ => unreachable!("not an inner node"),
        }
    }

    /// First child whose byte is >= `from` (0..=256). This one function is all
    /// the iterator needs to walk any layout in key order.
    fn next_child(&self, r: Ref, from: u16) -> Option<(u8, Ref)> {
        match r {
            Ref::N4(id) => self.pools.n4.items[id as usize].next_child(from),
            Ref::N16(id) => self.pools.n16.items[id as usize].next_child(from),
            Ref::N48(id) => {
                let n = &self.pools.n48.items[id as usize];
                (from..256).find(|&b| n.index[b as usize] != EMPTY48).map(|b| (b as u8, n.children[n.index[b as usize] as usize]))
            }
            Ref::N256(id) => {
                let n = &self.pools.n256.items[id as usize];
                (from..256).find(|&b| n.children[b as usize] != Ref::None).map(|b| (b as u8, n.children[b as usize]))
            }
            _ => unreachable!("not an inner node"),
        }
    }

    fn child_count(&self, r: Ref) -> usize {
        match r {
            Ref::N4(id) => self.pools.n4.items[id as usize].count as usize,
            Ref::N16(id) => self.pools.n16.items[id as usize].count as usize,
            Ref::N48(id) => self.pools.n48.items[id as usize].count as usize,
            Ref::N256(id) => self.pools.n256.items[id as usize].count as usize,
            _ => unreachable!("not an inner node"),
        }
    }

    // ---- Inspection ---------------------------------------------------

    pub fn census(&self) -> Census {
        let mut c = Census::default();
        self.census_at(self.root, 0, &mut c);
        c
    }

    fn census_at(&self, r: Ref, path: usize, c: &mut Census) {
        match r {
            Ref::None => {}
            Ref::Leaf(_) => {
                c.leaves += 1;
                c.max_path = c.max_path.max(path);
            }
            Ref::Prefix(id) => {
                c.nodes[Kind::Prefix as usize] += 1;
                self.census_at(self.pools.prefix.items[id as usize].child, path + 1, c);
            }
            _ => {
                let k = kind_of_ref(r) as usize;
                c.nodes[k] += 1;
                c.slots_used += self.child_count(r);
                c.slots_allocated += KIND_SLOTS[k];
                let mut from = 0;
                while let Some((byte, child)) = self.next_child(r, from) {
                    self.census_at(child, path + 1, c);
                    from = u16::from(byte) + 1;
                }
            }
        }
    }

    /// Check every structural invariant. Tests call this after each change.
    pub fn validate(&self) -> Result<(), &'static str> {
        self.validate_at(self.root)?;
        let c = self.census();
        // Every stored key ends in exactly one leaf.
        if c.leaves != self.len {
            return Err("leaf count differs from len");
        }
        // Every node handed out by a slab is reachable: nothing leaked inside
        // the tree, nothing freed twice.
        if c.nodes != self.pools.live {
            return Err("reachable nodes differ from live pool nodes");
        }
        Ok(())
    }

    fn validate_small<const CAP: usize>(&self, n: &SmallNode<CAP>, min: usize) -> Result<(), &'static str> {
        let count = n.count as usize;
        // An inner node branches (>= 2 children), and without delete a
        // Node16 only exists because a Node4 overflowed.
        if count < min || count > CAP {
            return Err("small node: bad count");
        }
        // Sorted, distinct bytes: iteration order and `find` rely on it.
        if n.keys[..count].windows(2).any(|w| w[0] >= w[1]) {
            return Err("small node: bytes not sorted");
        }
        for &child in &n.children[..count] {
            if child == Ref::None {
                return Err("small node: empty child");
            }
            self.validate_at(child)?;
        }
        Ok(())
    }

    fn validate_at(&self, r: Ref) -> Result<(), &'static str> {
        match r {
            Ref::None | Ref::Leaf(_) => Ok(()),
            Ref::Prefix(id) => {
                let p = &self.pools.prefix.items[id as usize];
                if p.len == 0 || p.len as usize > PREFIX_CAP || p.child == Ref::None {
                    return Err("bad prefix node");
                }
                self.validate_at(p.child)
            }
            Ref::N4(id) => self.validate_small(&self.pools.n4.items[id as usize], 2),
            Ref::N16(id) => self.validate_small(&self.pools.n16.items[id as usize], 5),
            Ref::N48(id) => {
                let n = &self.pools.n48.items[id as usize];
                if n.count < 17 || n.count > 48 {
                    return Err("node48: bad count");
                }
                // `index` must be a one-to-one map onto children[..count].
                let mut seen = [false; 48];
                let mut used = 0;
                for &slot in &n.index {
                    if slot == EMPTY48 {
                        continue;
                    }
                    if slot >= n.count || seen[slot as usize] {
                        return Err("node48: bad index");
                    }
                    seen[slot as usize] = true;
                    used += 1;
                    self.validate_at(n.children[slot as usize])?;
                }
                if used != n.count { Err("node48: index and count disagree") } else { Ok(()) }
            }
            Ref::N256(id) => {
                let n = &self.pools.n256.items[id as usize];
                let mut used = 0;
                for &child in &n.children {
                    if child != Ref::None {
                        used += 1;
                        self.validate_at(child)?;
                    }
                }
                if used != n.count || used < 49 { Err("node256: bad count") } else { Ok(()) }
            }
        }
    }

    /// Print the tree, one line per branch:
    ///
    /// ```text
    /// prefix "rom" -> node4 [2]
    ///   'a' -> prefix "n" -> ...
    /// ```
    pub fn dump(&self) -> String {
        let mut out = String::new();
        if self.root == Ref::None {
            out.push_str("(empty)\n");
        } else {
            self.dump_at(self.root, &mut out, 0);
        }
        out
    }

    fn dump_at(&self, r: Ref, out: &mut String, indent: usize) {
        match r {
            Ref::None => unreachable!("empty subtrees are never linked"),
            Ref::Leaf(v) => writeln!(out, "leaf {v}").expect("writing to a String cannot fail"),
            Ref::Prefix(id) => {
                let p = &self.pools.prefix.items[id as usize];
                out.push_str("prefix \"");
                keys::write_bytes(out, p.slice());
                out.push_str("\" -> ");
                self.dump_at(p.child, out, indent);
            }
            _ => {
                writeln!(out, "{} [{}]", KIND_NAMES[kind_of_ref(r) as usize], self.child_count(r))
                    .expect("writing to a String cannot fail");
                let mut from = 0;
                while let Some((byte, child)) = self.next_child(r, from) {
                    out.push_str(&" ".repeat(indent + 2));
                    out.push('\'');
                    keys::write_bytes(out, &[byte]);
                    out.push_str("' -> ");
                    self.dump_at(child, out, indent + 2);
                    from = u16::from(byte) + 1;
                }
            }
        }
    }

    pub fn iterator(&self) -> Iter<'_> {
        Iter { tree: self, stack: Vec::new(), key: Vec::new(), pending: self.root }
    }
}

fn kind_of_ref(r: Ref) -> Kind {
    match r {
        Ref::Prefix(_) => Kind::Prefix,
        Ref::N4(_) => Kind::Node4,
        Ref::N16(_) => Kind::Node16,
        Ref::N48(_) => Kind::Node48,
        Ref::N256(_) => Kind::Node256,
        Ref::None | Ref::Leaf(_) => unreachable!("not a node"),
    }
}

/// Ordered iteration. An ART has no leaf chain to follow, so the iterator
/// keeps the path from the root as an explicit stack, and rebuilds the current
/// key from the bytes along that path (DuckDB: iterator.cpp:312-348).
///
/// The shared borrow of the tree makes "the tree must not change while an
/// iterator is in use" a compile-time rule here; in Zig it is a comment.
#[derive(Debug)]
pub struct Iter<'a> {
    tree: &'a Art,
    /// One frame per inner node on the current path.
    stack: Vec<Frame>,
    /// The key bytes consumed along the current path.
    key: Vec<u8>,
    /// A subtree that still has to be entered (set by `iterator` and `seek`).
    pending: Ref,
}

#[derive(Debug)]
struct Frame {
    node: Ref,
    /// Next byte value to try in `node`, 0..=256.
    next: u16,
    /// Length of `key` when standing at `node`.
    key_len: usize,
}

impl Iter<'_> {
    /// Next entry in ascending key order. `entry.key` borrows the iterator's
    /// own buffer, so it is valid until the next call. That makes this a
    /// "lending" iterator, which `std::iter::Iterator` cannot express; hence
    /// an inherent method.
    #[allow(clippy::should_implement_trait)]
    pub fn next(&mut self) -> Option<Entry<'_>> {
        // The value is found first and the key borrowed once at the end:
        // returning `self.key` from inside the loop would hold the borrow
        // across the next iteration.
        let value = self.advance()?;
        Some(Entry { key: &self.key, value })
    }

    fn advance(&mut self) -> Option<u64> {
        if self.pending != Ref::None {
            let r = std::mem::replace(&mut self.pending, Ref::None);
            if let Some(v) = self.descend(r) {
                return Some(v);
            }
        }
        while let Some(top) = self.stack.last_mut() {
            self.key.truncate(top.key_len);
            if let Some((byte, child)) = self.tree.next_child(top.node, top.next) {
                top.next = u16::from(byte) + 1;
                self.key.push(byte);
                if let Some(v) = self.descend(child) {
                    return Some(v);
                }
            } else {
                self.stack.pop(); // node exhausted: back to its parent
            }
        }
        None
    }

    /// Walk down from `start` through prefix nodes. A leaf is the next entry.
    /// An inner node is pushed so that `next` continues with its first child.
    fn descend(&mut self, start: Ref) -> Option<u64> {
        let mut r = start;
        loop {
            match r {
                Ref::None => return None,
                Ref::Leaf(v) => return Some(v),
                Ref::Prefix(id) => {
                    let p = &self.tree.pools.prefix.items[id as usize];
                    self.key.extend_from_slice(p.slice());
                    r = p.child;
                }
                _ => {
                    self.stack.push(Frame { node: r, next: 0, key_len: self.key.len() });
                    return None;
                }
            }
        }
    }

    /// Position the iterator so that `next` returns the first key >= `lo`
    /// (lower bound). `lo` is any byte string; it need not be a stored key.
    pub fn seek(&mut self, lo: &[u8]) {
        self.stack.clear();
        self.key.clear();
        self.pending = Ref::None;
        let mut r = self.tree.root;
        let mut depth = 0;
        loop {
            match r {
                Ref::None => return,
                Ref::Leaf(_) => {
                    // Path == lo[..depth]. Equal if lo ends here; otherwise the
                    // stored key is a strict prefix of lo, hence smaller: skip.
                    if depth == lo.len() {
                        self.pending = r;
                    }
                    return;
                }
                Ref::Prefix(id) => {
                    let p = &self.tree.pools.prefix.items[id as usize];
                    let rest = &lo[depth..];
                    let stored = p.slice();
                    let n = rest.len().min(stored.len());
                    match stored[..n].cmp(&rest[..n]) {
                        // Every key below is smaller than lo: nothing here.
                        Ordering::Less => return,
                        // Every key below is greater than lo: take it all.
                        Ordering::Greater => {
                            self.pending = r;
                            return;
                        }
                        Ordering::Equal => {}
                    }
                    if rest.len() < stored.len() {
                        // lo ended inside the prefix: all keys below extend lo.
                        self.pending = r;
                        return;
                    }
                    self.key.extend_from_slice(stored);
                    depth += stored.len();
                    r = p.child;
                }
                _ => {
                    if depth == lo.len() {
                        self.pending = r;
                        return;
                    }
                    let byte = lo[depth];
                    // Children with a greater byte are all > lo: `next` will
                    // visit them after whatever we find below `byte`.
                    self.stack.push(Frame { node: r, next: u16::from(byte) + 1, key_len: self.key.len() });
                    let Some(child) = self.tree.child_of(r, byte) else {
                        return;
                    };
                    self.key.push(byte);
                    depth += 1;
                    r = child;
                }
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use crate::keys::{decode_u64, encode_u64};
    use crate::ops::{Config, Op, OpStream, Oracle, Weights};
    use crate::prng::SplitMix64;

    #[test]
    fn empty_tree() {
        let tree = Art::new();
        assert_eq!(tree.get(b"a"), None);
        tree.validate().unwrap();
        assert_eq!(tree.dump(), "(empty)\n");
        assert!(tree.iterator().next().is_none());
    }

    #[test]
    fn first_key_is_one_prefix_chain_long_keys_chain_prefix_nodes() {
        let mut tree = Art::new();
        assert_eq!(tree.put(b"abcdefghij", 1), Ok(None));
        assert_eq!(tree.dump(), "prefix \"abcdefg\" -> prefix \"hij\" -> leaf 1\n");
        assert_eq!(tree.get(b"abcdefghij"), Some(1));
        assert_eq!(tree.get(b"abcdefghi"), None);
        assert_eq!(tree.get(b"abcdefghijk"), None);
        assert_eq!(tree.put(b"abcdefghij", 2), Ok(Some(1))); // overwrite
        assert_eq!(tree.len(), 1);
        tree.validate().unwrap();
    }

    #[test]
    fn prefix_split_head_kept_tail_kept_both_neither() {
        let mut tree = Art::new();
        tree.put(b"abcd", 1).unwrap();
        tree.put(b"abxy", 2).unwrap(); // split in the middle: head "ab", tails "d" and "y"
        assert_eq!(
            tree.dump(),
            "prefix \"ab\" -> node4 [2]\n\
             \x20 'c' -> prefix \"d\" -> leaf 1\n\
             \x20 'x' -> prefix \"y\" -> leaf 2\n"
        );
        tree.put(b"zz", 3).unwrap(); // split at byte 0, tail "b" reuses the node
        assert_eq!(
            tree.dump(),
            "node4 [2]\n\
             \x20 'a' -> prefix \"b\" -> node4 [2]\n\
             \x20   'c' -> prefix \"d\" -> leaf 1\n\
             \x20   'x' -> prefix \"y\" -> leaf 2\n\
             \x20 'z' -> prefix \"z\" -> leaf 3\n"
        );
        tree.put(b"ac", 4).unwrap(); // 1-byte prefix "b" dissolves into a branch
        assert_eq!(
            tree.dump(),
            "node4 [2]\n\
             \x20 'a' -> node4 [2]\n\
             \x20   'b' -> node4 [2]\n\
             \x20     'c' -> prefix \"d\" -> leaf 1\n\
             \x20     'x' -> prefix \"y\" -> leaf 2\n\
             \x20   'c' -> leaf 4\n\
             \x20 'z' -> prefix \"z\" -> leaf 3\n"
        );
        assert_eq!(tree.prefix_splits, 3);
        tree.validate().unwrap();
        for (k, v) in [&b"abcd"[..], b"abxy", b"zz", b"ac"].into_iter().zip(1..) {
            assert_eq!(tree.get(k), Some(v));
        }
    }

    #[test]
    fn keys_that_are_prefixes_of_each_other_are_rejected_without_side_effects() {
        let mut tree = Art::new();
        assert_eq!(tree.put(b"", 1), Err(ArtError::EmptyKey));
        tree.put(b"abc", 1).unwrap();
        tree.put(b"abd", 2).unwrap();
        assert_eq!(tree.put(b"ab", 3), Err(ArtError::PrefixKey)); // ends at an inner node
        assert_eq!(tree.put(b"a", 3), Err(ArtError::PrefixKey)); // ends inside a prefix
        assert_eq!(tree.put(b"abcd", 3), Err(ArtError::PrefixKey)); // continues past a leaf
        assert_eq!(tree.len(), 2);
        tree.validate().unwrap();
    }

    #[test]
    fn one_node_grows_through_all_four_layouts() {
        let mut tree = Art::new();
        let expected = [
            (2, Kind::Node4),
            (4, Kind::Node4),
            (5, Kind::Node16),
            (16, Kind::Node16),
            (17, Kind::Node48),
            (48, Kind::Node48),
            (49, Kind::Node256),
            (256, Kind::Node256),
        ];
        let mut next_check = 0;
        // Descending byte order exercises the sorted insert of Node4 / Node16.
        for i in 0..256u64 {
            tree.put(&[b'k', (255 - i) as u8], i).unwrap();
            tree.validate().unwrap();
            if next_check < expected.len() && expected[next_check].0 == i + 1 {
                let Ref::Prefix(id) = tree.root else { panic!("root is the prefix \"k\"") };
                assert_eq!(kind_of_ref(tree.pools.prefix.items[id as usize].child), expected[next_check].1);
                next_check += 1;
            }
        }
        assert_eq!(next_check, expected.len());
        assert_eq!(tree.grows, [1, 1, 1]);
        // The three outgrown nodes went back to their slabs.
        assert_eq!(tree.pool_live(), [1, 0, 0, 0, 1]);
        assert_eq!(tree.pool_created(), [1, 1, 1, 1, 1]);
        for i in 0..256u64 {
            assert_eq!(tree.get(&[b'k', (255 - i) as u8]), Some(i));
        }
    }

    #[test]
    fn a_freed_node_is_reused_by_its_pool() {
        let mut tree = Art::new();
        for i in 0..5u8 {
            tree.put(&[b'a', i], u64::from(i)).unwrap(); // Node4 -> Node16, Node4 freed
        }
        let freed_created = tree.pool_created()[Kind::Node4 as usize];
        tree.put(&[b'b', 0], 9).unwrap(); // needs a Node4 for the new branch at byte 0
        assert_eq!(tree.pool_created()[Kind::Node4 as usize], freed_created + 1);
        assert_eq!(tree.pool_live()[Kind::Node4 as usize], 1);
        assert_eq!(tree.pools.n4.items.len(), 1); // the same slot, not a second one
        tree.validate().unwrap();
    }

    #[test]
    fn the_longest_keys_recursion_depth_is_bounded_by_max_key_len() {
        let mut tree = Art::new();
        let mut buf = [b'a'; MAX_KEY_LEN + 1];

        // One byte too long: refused before anything is touched.
        assert_eq!(tree.put(&buf, 1), Err(ArtError::KeyTooLong));
        assert_eq!(tree.len(), 0);
        tree.validate().unwrap();
        assert_eq!(tree.dump(), "(empty)\n");

        // The deepest tree the limit allows: keys "b", "ab", "aab", ... up to
        // MAX_KEY_LEN bytes. Every byte position branches, so the path to the
        // longest key has one Node4 per byte and every recursive walk goes
        // MAX_KEY_LEN levels deep.
        for i in 0..MAX_KEY_LEN {
            buf[i] = b'b';
            assert_eq!(tree.put(&buf[..=i], i as u64), Ok(None));
            buf[i] = b'a';
        }
        // And the longest unbranched key: a chain of 73 prefix nodes.
        buf[..MAX_KEY_LEN].fill(b'c');
        assert_eq!(tree.put(&buf[..MAX_KEY_LEN], 7), Ok(None));
        assert_eq!(tree.put(&buf[..MAX_KEY_LEN], 8), Ok(Some(7))); // overwrite walks the chain

        tree.validate().unwrap();
        let c = tree.census();
        assert_eq!(c.nodes[Kind::Node4 as usize], MAX_KEY_LEN - 1);
        assert_eq!(c.max_path, MAX_KEY_LEN);
        assert_eq!(c.leaves, MAX_KEY_LEN + 1);
        assert!(tree.dump().ends_with("\" -> leaf 8\n"));

        buf[..MAX_KEY_LEN].fill(b'a');
        buf[MAX_KEY_LEN - 1] = b'b';
        assert_eq!(tree.get(&buf[..MAX_KEY_LEN]), Some(MAX_KEY_LEN as u64 - 1));
        let mut it = tree.iterator();
        let mut n = 0;
        while it.next().is_some() {
            n += 1;
        }
        assert_eq!(n, MAX_KEY_LEN + 1);
    }

    #[test]
    fn iterator_returns_keys_in_byte_order_and_seek_is_a_lower_bound() {
        let mut tree = Art::new();
        let words: [&[u8]; 7] = [b"romulus!", b"romane!", b"rubens!", b"romanus!", b"ruber!", b"rubicon!", b"rubicundus!"];
        for (word, i) in words.into_iter().zip(0..) {
            tree.put(word, i).unwrap();
        }
        let mut it = tree.iterator();
        let sorted: [&[u8]; 7] = [b"romane!", b"romanus!", b"romulus!", b"rubens!", b"ruber!", b"rubicon!", b"rubicundus!"];
        for want in sorted {
            assert_eq!(it.next().unwrap().key, want);
        }
        assert!(it.next().is_none());

        let cases: [(&[u8], Option<&[u8]>); 11] = [
            (b"", Some(b"romane!")),
            (b"romane!", Some(b"romane!")),   // exact hit
            (b"romane", Some(b"romane!")),    // lo is a prefix of a key
            (b"romane!!", Some(b"romanus!")), // a key is a prefix of lo
            (b"romb", Some(b"romulus!")),     // no child at that byte
            (b"roz", Some(b"rubens!")),       // greater than a whole prefix
            (b"ra", Some(b"romane!")),        // smaller than a whole prefix
            (b"rubf", Some(b"rubicon!")),
            (b"rubicundus!", Some(b"rubicundus!")),
            (b"rubz", None),
            (b"s", None),
        ];
        for (lo, first) in cases {
            it.seek(lo);
            assert_eq!(it.next().map(|e| e.key.to_vec()), first.map(<[u8]>::to_vec));
        }
    }

    /// Collect the entries of all keys in [lo, hi) through the iterator.
    fn collect_range(tree: &Art, lo: &[u8], hi: &[u8]) -> Vec<(u64, u64)> {
        let mut out = Vec::new();
        let mut it = tree.iterator();
        it.seek(lo);
        while let Some(e) = it.next() {
            if e.key >= hi {
                break;
            }
            out.push((decode_u64(e.key), e.value));
        }
        out
    }

    #[test]
    fn model_test_against_the_oracle_put_get_range_on_u64_keys() {
        // (seed, key space): a tiny space forces overwrites and dense nodes, a
        // huge one gives sparse keys with long prefixes.
        for (seed, key_space) in [(1, 300), (2, 70_000), (3, 1 << 40)] {
            let mut tree = Art::new();
            let mut oracle = Oracle::new();
            let stream = OpStream::new(Config {
                seed,
                count: 4000,
                key_space,
                weights: Weights { put: 5, delete: 0, get: 3, range: 2 }, // no delete in this chapter
            });
            for (n, op) in stream.enumerate() {
                match op {
                    Op::Put { key, value } => assert_eq!(tree.put(&encode_u64(key), value), Ok(oracle.put(key, value))),
                    Op::Get { key } => assert_eq!(tree.get(&encode_u64(key)), oracle.get(key)),
                    Op::Range { lo, hi } => {
                        let got = collect_range(&tree, &encode_u64(lo), &encode_u64(hi));
                        let want: Vec<(u64, u64)> = oracle.range(lo, hi).iter().map(|e| (e.key, e.value)).collect();
                        assert_eq!(got, want);
                    }
                    Op::Delete { .. } => unreachable!(),
                }
                if n % 64 == 0 {
                    tree.validate().unwrap();
                }
            }
            tree.validate().unwrap();
            assert_eq!(tree.len(), oracle.len());
        }
    }

    /// Twin of Zig's "allocation failure at every point": instead of failing
    /// the Nth allocation, cap the number of live nodes at every possible value.
    #[test]
    fn node_budget_exhaustion_at_every_point_leaves_the_tree_unchanged() {
        // Mixed key shapes so that failures land in chain building, prefix
        // splits and all three grow steps.
        let mut budget = 0;
        loop {
            let mut tree = Art::with_node_budget(budget);
            let mut rng = SplitMix64::new(99);
            let mut inserted = Vec::new();
            let mut failures = 0;
            for i in 0..300u64 {
                // Low byte dense (drives one node to Node256), high bytes sparse.
                let k = if i % 3 == 0 { rng.below(256) } else { rng.next_u64() };
                let before = tree.census();
                let had = tree.get(&encode_u64(k));
                match tree.put(&encode_u64(k), i) {
                    Ok(_) => inserted.push(k),
                    Err(e) => {
                        assert_eq!(e, ArtError::OutOfNodes);
                        failures += 1;
                        // Nothing changed: same shape, same answer for the failed key.
                        tree.validate().unwrap();
                        assert_eq!(tree.census(), before);
                        assert_eq!(tree.get(&encode_u64(k)), had);
                    }
                }
            }
            tree.validate().unwrap();
            assert!(inserted.iter().all(|&k| tree.get(&encode_u64(k)).is_some()));
            if failures == 0 {
                break; // the budget was never reached
            }
            budget += 1;
        }
        assert!(budget > 10); // the loop really exercised several failure points
    }
}
