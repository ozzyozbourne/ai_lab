//! The single-threaded algorithm. Correct only while the caller holds a lock
//! that keeps every other thread out (tree.rs takes the tree-wide mutex or
//! reader-writer lock around these two functions).
//!
//! Zig's version takes no latch at all here. Rust cannot do that without
//! `unsafe`: a node lives INSIDE its `RwLock`, and the only way in is a
//! guard. So this code takes each node's latch as it goes. Nobody else can
//! hold one (the tree-wide lock is held), so a latch never waits; it only
//! satisfies the type system. `get` holds one at a time and makes no attempt
//! to couple them.
//!
//! Compare with coupled.rs: the searches and the splits are the same; that
//! file adds the order in which latches are taken and released.

use crate::base_node::{Kind, OutOfNodes};
use crate::base_search::{child_index, lower_bound};
use crate::insert::{Held, insert_at_leaf};
use crate::tree::Tree;

pub fn get(tree: &Tree, key: u64) -> Option<u64> {
    let mut id = tree.root();
    loop {
        let node = tree.table.read(id);
        match &node.kind {
            Kind::Internal(internal) => {
                id = internal.children[child_index(node.key_slice(), key)];
            }
            Kind::Leaf(leaf) => {
                let i = lower_bound(node.key_slice(), key);
                return (i < node.len && node.keys[i] == key).then(|| leaf.values[i]);
            }
        }
    }
}

pub fn put(tree: &Tree, key: u64, value: u64) -> Result<Option<u64>, OutOfNodes> {
    // Remember the whole path: any node on it may have to split.
    let mut path: Vec<Held<'_>> = Vec::new();
    let mut id = tree.root();
    loop {
        let node = tree.table.write(id);
        let child = match &node.kind {
            Kind::Internal(internal) => Some(internal.children[child_index(node.key_slice(), key)]),
            Kind::Leaf(_) => None,
        };
        path.push((id, node));
        match child {
            Some(child) => id = child,
            None => break,
        }
    }
    insert_at_leaf(tree, &mut path, true, key, value)
}
