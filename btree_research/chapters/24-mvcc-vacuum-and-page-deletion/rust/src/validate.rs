//! `validate`: every invariant of index.rs and store.rs as code, naming the
//! first one that is broken. It trusts no handle it reads: each one is
//! checked with `is_live` before it is followed.

use crate::base_arena::NodeId;
use crate::base_node::{self as node, Kind, PageState};
use crate::db::Db;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Violation {
    /// root / first_leaf / height disagree about emptiness.
    BadRoot,
    /// A child handle is nil, out of range, or names a freed slot.
    DanglingChild,
    NodeOverfull,
    KeysNotSorted,
    /// A key lies outside the range its ancestors' separators allow.
    KeyOutOfBounds,
    UnevenLeafDepth,
    /// A page reachable from the root is half-dead or deleted.
    DeadPageInTree,
    /// The right links do not visit the tree's leaves in order.
    BrokenLeafChain,
    /// The deleted queue is not exactly the deleted pages in stamp order.
    BadDeletedQueue,
    /// An entry's tid is not a live version of the same key.
    DanglingTid,
    /// Entries and versions are not one-to-one.
    WrongCount,
    /// Two versions of one key are both undeleted.
    TwoCurrentVersions,
    /// A hint bit on an entry whose version somebody could still see.
    LyingHint,
    /// xmin/xmax/snapshot from the future, or xmax < xmin.
    BadTimestamp,
    /// Live pages that nothing accounts for, or a corrupt free list.
    ArenaLeak,
}

struct Walk {
    /// Next live leaf the chain should deliver (half-dead pages skipped).
    chain: NodeId,
    pages: usize,
    entries: usize,
    /// User key of the last undeleted version seen, to catch two of them.
    last_current: Option<u64>,
}

pub fn validate(db: &Db) -> Result<(), Violation> {
    let index = &db.index;
    let store = &db.store;
    let mut pages = 0;
    if index.root.is_nil() {
        if !index.first_leaf.is_nil() || index.height != 0 || index.count != 0 {
            return Err(Violation::BadRoot);
        }
    } else {
        if !index.nodes.is_live(index.root) {
            return Err(Violation::BadRoot);
        }
        let mut walk = Walk {
            chain: index.first_leaf,
            pages: 0,
            entries: 0,
            last_current: None,
        };
        // Half-dead pages are in the chain but not in the tree: count them
        // while skipping to the first live leaf, and again after each leaf.
        skip_half_dead(db, &mut walk)?;
        check_node(db, index.root, 1, None, None, &mut walk)?;
        if !walk.chain.is_nil() {
            return Err(Violation::BrokenLeafChain);
        }
        if walk.entries != index.count {
            return Err(Violation::WrongCount);
        }
        pages = walk.pages;
    }
    // Entries are unique (strictly sorted) and each names a live version, so
    // equal counts make entries and versions one-to-one.
    if index.count != store.versions.live_count() {
        return Err(Violation::WrongCount);
    }

    // The deleted queue: deleted pages only, stamps ascending, proper tail.
    let mut last_stamp = 0;
    let mut tail = NodeId::NIL;
    let mut id = index.deleted_head;
    while !id.is_nil() {
        if !index.nodes.is_live(id) || !index.nodes.get(id).is_leaf() {
            return Err(Violation::BadDeletedQueue);
        }
        let leaf = index.nodes.get(id).leaf();
        let PageState::Deleted(stamp) = leaf.state else {
            return Err(Violation::BadDeletedQueue);
        };
        if stamp <= last_stamp || pages > index.nodes.slot_count() {
            return Err(Violation::BadDeletedQueue); // out of order, or a cycle
        }
        if stamp > store.now {
            return Err(Violation::BadTimestamp);
        }
        last_stamp = stamp;
        tail = id;
        id = leaf.next_deleted;
        pages += 1;
    }
    if tail != index.deleted_tail {
        return Err(Violation::BadDeletedQueue);
    }

    // Tree pages + half-dead pages + deleted pages are all the live slots.
    if pages != index.nodes.live_count() {
        return Err(Violation::ArenaLeak);
    }
    let free = index.nodes.free_count().ok_or(Violation::ArenaLeak)?;
    if free + index.nodes.live_count() != index.nodes.slot_count() {
        return Err(Violation::ArenaLeak);
    }
    if store.versions.free_count().is_none() {
        return Err(Violation::ArenaLeak);
    }
    if store.open.iter().any(|&s| s > store.now) {
        return Err(Violation::BadTimestamp);
    }
    Ok(())
}

fn skip_half_dead(db: &Db, walk: &mut Walk) -> Result<(), Violation> {
    while !walk.chain.is_nil() {
        if !db.index.nodes.is_live(walk.chain) {
            return Err(Violation::BrokenLeafChain);
        }
        let n = db.index.nodes.get(walk.chain);
        let Kind::Leaf(leaf) = &n.kind else {
            return Err(Violation::BrokenLeafChain);
        };
        match leaf.state {
            PageState::Deleted(_) => return Err(Violation::BrokenLeafChain),
            PageState::Live => return Ok(()),
            PageState::HalfDead => {}
        }
        if n.len != 0 {
            return Err(Violation::BrokenLeafChain); // only empty pages die
        }
        walk.pages += 1;
        walk.chain = leaf.next;
    }
    Ok(())
}

/// `lo` (inclusive) and `hi` (exclusive) are the bounds inherited from the
/// separators above; None means unbounded. Leaves are visited left to right,
/// so the visit order can be compared with the right links as we go.
fn check_node(
    db: &Db,
    id: NodeId,
    depth: usize,
    lo: Option<u64>,
    hi: Option<u64>,
    walk: &mut Walk,
) -> Result<(), Violation> {
    let index = &db.index;
    let n = index.nodes.get(id);
    let keys = n.key_slice();
    walk.pages += 1;
    if n.len > index.max_keys() {
        return Err(Violation::NodeOverfull);
    }
    for (i, &k) in keys.iter().enumerate() {
        if i > 0 && keys[i - 1] >= k {
            return Err(Violation::KeysNotSorted);
        }
        if lo.is_some_and(|lo| k < lo) || hi.is_some_and(|hi| k >= hi) {
            return Err(Violation::KeyOutOfBounds);
        }
    }
    match &n.kind {
        Kind::Leaf(leaf) => {
            if depth != index.height {
                return Err(Violation::UnevenLeafDepth);
            }
            if leaf.state != PageState::Live {
                return Err(Violation::DeadPageInTree);
            }
            if walk.chain != id {
                return Err(Violation::BrokenLeafChain);
            }
            walk.chain = leaf.next;
            skip_half_dead(db, walk)?;
            walk.entries += n.len;
            for (i, &k) in keys.iter().enumerate() {
                let tid = node::tid_of(k);
                if !db.store.versions.is_live(tid) {
                    return Err(Violation::DanglingTid);
                }
                let v = db.store.versions.get(tid);
                if v.key != node::user_key(k) {
                    return Err(Violation::DanglingTid);
                }
                if v.xmin > db.store.now || v.xmax > db.store.now {
                    return Err(Violation::BadTimestamp);
                }
                if v.xmax != 0 && v.xmax < v.xmin {
                    return Err(Violation::BadTimestamp);
                }
                if v.xmax == 0 {
                    if walk.last_current == Some(v.key) {
                        return Err(Violation::TwoCurrentVersions);
                    }
                    walk.last_current = Some(v.key);
                }
                if leaf.dead[i] && !db.store.dead_to_all(tid) {
                    return Err(Violation::LyingHint);
                }
            }
        }
        Kind::Internal(_) => {
            if depth >= index.height {
                return Err(Violation::UnevenLeafDepth);
            }
            for (i, &child) in n.child_slice().iter().enumerate() {
                if !index.nodes.is_live(child) {
                    return Err(Violation::DanglingChild);
                }
                let child_lo = if i == 0 { lo } else { Some(keys[i - 1]) };
                let child_hi = if i == n.len { hi } else { Some(keys[i]) };
                check_node(db, child, depth + 1, child_lo, child_hi, walk)?;
            }
        }
    }
    Ok(())
}
