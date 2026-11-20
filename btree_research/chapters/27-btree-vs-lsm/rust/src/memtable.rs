//! The memtable: the only mutable part of an LSM-tree, and it lives in RAM.
//!
//! It is a skip list (textbook; the classic choice since LevelDB). In Zig its
//! nodes are bump-allocated from an `ArenaAllocator`; the Rust idiom for the
//! same lifetime is two `Vec`s used as bump arenas:
//!   * `nodes`: one entry per key, named by a `u32` index instead of a pointer;
//!   * `towers`: all the `next` links of all nodes, back to back; a node owns
//!     the slice `towers[tower .. tower + height]`.
//!
//! A memtable only ever grows until it is flushed; then every node dies at the
//! same instant. `reset` is two `clear()` calls: nothing is walked, and the
//! capacity stays for the next memtable.
//!
//! A put of a key that is already in the memtable overwrites in place and
//! allocates nothing: the memtable absorbs repeated updates for free.
//! A delete is a put of a TOMBSTONE (`value == None`): the key may still
//! exist in an older run on the device, and only a newer entry can hide it.

use crate::prng::SplitMix64;
use crate::run::Slot;

/// Tallest tower. 2^8 = 256 keys per top-level step is plenty for a memtable
/// of a few hundred entries.
pub const MAX_HEIGHT: usize = 8;

/// "No node": end of a level's list.
pub const NIL: u32 = u32::MAX;

/// Result of looking a key up in ONE place (the memtable or one run).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Lookup {
    /// This place knows nothing about the key: keep looking in older data.
    Absent,
    /// The key was deleted: stop looking, the answer is "not found".
    Tombstone,
    Value(u64),
}

/// The memtable refused to grow past its node budget (the Rust stand-in for
/// Zig's `error.OutOfMemory`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct OutOfMemory;

impl std::fmt::Display for OutOfMemory {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("memory budget exhausted")
    }
}

impl std::error::Error for OutOfMemory {}

#[derive(Debug, Clone, Copy)]
struct Node {
    key: u64,
    /// None = tombstone.
    value: Option<u64>,
    /// Offset of this node's tower in `towers`, and its height.
    tower: u32,
    height: u8,
}

#[derive(Debug)]
pub struct Memtable {
    nodes: Vec<Node>,
    towers: Vec<u32>,
    /// head[h] is the first node on level h.
    head: [u32; MAX_HEIGHT],
    /// Tower heights come from a seeded generator so that runs are
    /// reproducible. The shape of the list never reaches the output.
    rng: SplitMix64,
    /// Most nodes allowed; `usize::MAX` for "no limit".
    max_nodes: usize,
}

impl Default for Memtable {
    fn default() -> Self {
        Self::new()
    }
}

impl Memtable {
    pub fn new() -> Memtable {
        Self::with_budget(usize::MAX)
    }

    /// A memtable that refuses to hold more than `max_nodes` keys.
    pub fn with_budget(max_nodes: usize) -> Memtable {
        Memtable {
            nodes: Vec::new(),
            towers: Vec::new(),
            head: [NIL; MAX_HEIGHT],
            rng: SplitMix64::new(27),
            max_nodes,
        }
    }

    /// Number of distinct keys (tombstones included).
    pub fn count(&self) -> usize {
        self.nodes.len()
    }

    /// Drops every node at once and keeps the memory for the next memtable.
    /// This is called right after a flush.
    pub fn reset(&mut self) {
        self.nodes.clear();
        self.towers.clear();
        self.head = [NIL; MAX_HEIGHT];
    }

    /// The node after `node` on level `h` (`NIL` stands for the head).
    fn next_on(&self, node: u32, h: usize) -> u32 {
        if node == NIL {
            return self.head[h];
        }
        let n = &self.nodes[node as usize];
        if h < n.height as usize { self.towers[n.tower as usize + h] } else { NIL }
    }

    /// Finds, per level, the last node with key < `key` (`NIL` = the head).
    /// Returns the predecessors and the node at or after `key` on level 0.
    fn find_predecessors(&self, key: u64) -> ([u32; MAX_HEIGHT], u32) {
        let mut preds = [NIL; MAX_HEIGHT];
        let mut pred = NIL;
        for h in (0..MAX_HEIGHT).rev() {
            // Walk right on level h while the next key is still too small,
            // then drop one level: the skip list's version of a descent.
            loop {
                let next = self.next_on(pred, h);
                if next == NIL || self.nodes[next as usize].key >= key {
                    break;
                }
                pred = next;
            }
            preds[h] = pred;
        }
        (preds, self.next_on(pred, 0))
    }

    /// Inserts or overwrites; `value == None` writes a tombstone.
    /// On `Err(OutOfMemory)` the memtable is unchanged.
    pub fn put(&mut self, key: u64, value: Option<u64>) -> Result<(), OutOfMemory> {
        let (preds, found) = self.find_predecessors(key);
        if found != NIL && self.nodes[found as usize].key == key {
            self.nodes[found as usize].value = value;
            return Ok(());
        }
        if self.nodes.len() >= self.max_nodes {
            return Err(OutOfMemory);
        }
        // Height h with probability 2^-h: count the trailing one bits.
        let height = MAX_HEIGHT.min(1 + (!self.rng.next_u64()).trailing_zeros() as usize);
        let id = u32::try_from(self.nodes.len()).expect("memtable fits in 32 bits");
        let tower = u32::try_from(self.towers.len()).expect("towers fit in 32 bits");
        // Splice the node in on each level.
        for (h, &pred) in preds.iter().enumerate().take(height) {
            self.towers.push(self.next_on(pred, h));
            if pred == NIL {
                self.head[h] = id;
            } else {
                let p = self.nodes[pred as usize];
                self.towers[p.tower as usize + h] = id;
            }
        }
        self.nodes.push(Node { key, value, tower, height: height as u8 });
        Ok(())
    }

    pub fn get(&self, key: u64) -> Lookup {
        let (_, found) = self.find_predecessors(key);
        if found == NIL || self.nodes[found as usize].key != key {
            return Lookup::Absent;
        }
        match self.nodes[found as usize].value {
            Some(v) => Lookup::Value(v),
            None => Lookup::Tombstone,
        }
    }

    /// First node with key >= `key`; pass it to `slot` and `next` to iterate.
    pub fn seek(&self, key: u64) -> u32 {
        self.find_predecessors(key).1
    }

    pub fn first(&self) -> u32 {
        self.head[0]
    }

    /// The node after `node` in key order, or `NIL`.
    pub fn next(&self, node: u32) -> u32 {
        self.next_on(node, 0)
    }

    pub fn slot(&self, node: u32) -> Slot {
        let n = &self.nodes[node as usize];
        Slot { key: n.key, value: n.value }
    }

    /// All slots in key order, starting at `node`.
    pub fn iter_from(&self, node: u32) -> impl Iterator<Item = Slot> + '_ {
        let mut at = node;
        std::iter::from_fn(move || {
            if at == NIL {
                return None;
            }
            let slot = self.slot(at);
            at = self.next(at);
            Some(slot)
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn put_overwrite_tombstone_ordered_iteration() {
        let mut m = Memtable::new();
        for k in [50, 10, 40, 20, 30] {
            m.put(k, Some(k * 10)).unwrap();
        }
        m.put(40, Some(444)).unwrap(); // overwrite: no new node
        m.put(20, None).unwrap(); // tombstone
        m.put(25, None).unwrap(); // tombstone for a key that was never here
        assert_eq!(m.count(), 6);
        assert_eq!(m.get(40), Lookup::Value(444));
        assert_eq!(m.get(20), Lookup::Tombstone);
        assert_eq!(m.get(21), Lookup::Absent);

        let keys: Vec<u64> = m.iter_from(m.first()).map(|s| s.key).collect();
        assert_eq!(keys, [10, 20, 25, 30, 40, 50]);
        assert_eq!(m.slot(m.seek(26)).key, 30);
        assert_eq!(m.seek(51), NIL);
    }

    #[test]
    fn reset_frees_every_node_at_once_and_the_memory_is_reused() {
        let mut m = Memtable::new();
        for k in 0..200 {
            m.put(k, Some(k)).unwrap();
        }
        let capacity = (m.nodes.capacity(), m.towers.capacity());
        m.reset();
        assert_eq!(m.count(), 0);
        assert_eq!(m.get(7), Lookup::Absent);
        // The second generation fits into the memory of the first. (Tower
        // heights differ a little between generations, so allow the towers
        // to have grown; the nodes cannot have.)
        for k in 0..200 {
            m.put(k + 1000, Some(k)).unwrap();
        }
        assert_eq!(m.nodes.capacity(), capacity.0);
        assert_eq!(m.count(), 200);
    }

    #[test]
    fn a_failed_put_leaves_the_memtable_unchanged() {
        for budget in 0..12 {
            let mut m = Memtable::with_budget(budget);
            let mut stored = 0;
            for k in 0..40u64 {
                match m.put(k * 3, Some(k)) {
                    Ok(()) => stored += 1,
                    Err(OutOfMemory) => assert_eq!(m.get(k * 3), Lookup::Absent),
                }
            }
            assert_eq!(stored, budget);
            assert_eq!(m.count(), stored);
            assert_eq!(m.iter_from(m.first()).count(), stored);
            // Overwriting needs no node, so it still works when full.
            if budget > 0 {
                assert_eq!(m.put(0, None), Ok(()));
                assert_eq!(m.get(0), Lookup::Tombstone);
            }
        }
    }
}
