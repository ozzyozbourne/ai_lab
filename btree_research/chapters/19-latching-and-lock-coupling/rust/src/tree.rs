//! One B+tree, three ways of letting several threads use it.
//!
//!   GlobalMutex    one mutex around every operation. One thread at a time.
//!   GlobalRwLock   one reader-writer lock around every operation. Any
//!                  number of `get`s together, or one `put` alone.
//!   LatchCoupling  one reader-writer LATCH per node; an operation holds
//!                  only the latches of the nodes it is working on
//!                  (coupled.rs).
//!
//! The first two wrap the plain single-threaded algorithm of plain.rs. All
//! three produce exactly the same tree for the same sequence of operations;
//! they differ only in what a second thread may do meanwhile.
//!
//! Invariants (checked by `validate`, see validate.rs):
//!   1. Entries live only in leaves; keys inside a node are strictly ascending.
//!   2. An internal node with k keys has k+1 children; child i holds only
//!      keys in [keys[i-1], keys[i]).
//!   3. A node has at most M-1 keys; every node except the root has at least
//!      ceil(M/2)-1; an internal root has at least 1 key.
//!   4. All leaves are at the same depth and are chained in key order.
//!   5. Every slot handed out by the node table is reachable from the root.

use std::sync::atomic::{AtomicU32, AtomicUsize, Ordering};
use std::sync::{Mutex, MutexGuard, RwLock, RwLockReadGuard, RwLockWriteGuard, TryLockError};

use crate::base_node::{Kind, MAX_ORDER, Node, NodeId, OutOfNodes};
use crate::table::NodeTable;
use crate::{coupled, plain};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Protocol {
    GlobalMutex,
    GlobalRwLock,
    LatchCoupling,
}

/// Shared: many holders, all of them only read. Exclusive: one holder.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Mode {
    Shared,
    Exclusive,
}

/// Counters. Atomics, because under latch coupling two threads may split
/// different leaves at the same moment.
#[derive(Debug, Default)]
pub struct Stats {
    pub leaf_splits: AtomicUsize,
    pub internal_splits: AtomicUsize,
    /// Times an operation latched a node that was no longer the root and
    /// started again (latch coupling only).
    pub root_restarts: AtomicUsize,
}

/// A point at which an operation calls its test hook.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Point {
    /// Latch coupling: the root id was read; no latch is held yet.
    RootLoaded,
    /// Latch coupling: a latch on `node` was acquired.
    Latched,
    /// The descent is over. Latch coupling: a `get` holds exactly the leaf
    /// (shared); a `put` holds the leaf and every unsafe ancestor
    /// (exclusive). Global protocols: the tree-wide lock is held.
    AtLeaf,
    /// The lock or latch on `node` could not be taken at once; the operation
    /// is about to wait for it. (`node` is `NIL` for the tree-wide lock.)
    /// With two threads that means "the other one holds it". With three or
    /// more it can also mean "a writer is already waiting for it": see the
    /// caveat in probe.rs.
    Blocked,
    /// A `put` that splits the root has filled in the new root `node` and is
    /// about to publish it. The root id still names the OLD root.
    RootBuilt,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Event {
    pub point: Point,
    pub node: NodeId,
}

/// Test hook: a callback that an operation calls at the points listed in
/// `Point`, ON ITS OWN THREAD and while holding whatever it holds at that
/// point. A test blocks inside the callback to freeze the operation there,
/// which turns "what if the other thread runs exactly now" into a
/// deterministic test. Production calls pass `None` and pay one branch.
pub type Hook<'a> = Option<&'a (dyn Fn(Event) + Sync)>;

pub fn emit(hook: Hook<'_>, point: Point, node: NodeId) {
    if let Some(f) = hook {
        f(Event { point, node });
    }
}

/// The tree-wide lock, whichever kind the protocol uses. Dropping it unlocks.
pub struct GlobalGuard<'a> {
    _mutex: Option<MutexGuard<'a, ()>>,
    _shared: Option<RwLockReadGuard<'a, ()>>,
    _exclusive: Option<RwLockWriteGuard<'a, ()>>,
}

pub struct Tree {
    /// M: maximum number of children of an internal node (Knuth's order).
    pub order: usize,
    pub protocol: Protocol,
    pub table: NodeTable,
    /// Handle of the root. Atomic, because under latch coupling a thread reads
    /// it before it holds any latch. It changes only when the root splits.
    root: AtomicU32,
    /// Number of entries.
    pub(crate) count: AtomicUsize,
    pub stats: Stats,
    /// The tree-wide lock of `GlobalMutex`.
    mutex: Mutex<()>,
    /// The tree-wide lock of `GlobalRwLock`.
    rwlock: RwLock<()>,
}

impl Tree {
    /// Allocates the whole node table (`node_count` nodes) and creates the
    /// root as an empty leaf, so that no operation has to handle "no root
    /// yet".
    pub fn new(order: usize, protocol: Protocol, node_count: u32) -> Tree {
        assert!((3..=MAX_ORDER).contains(&order));
        assert!(node_count >= 1);
        let table = NodeTable::new(node_count);
        let root = table.reserve(1).expect("node_count >= 1");
        Tree {
            order,
            protocol,
            table,
            root: AtomicU32::new(root.raw()),
            count: AtomicUsize::new(0),
            stats: Stats::default(),
            mutex: Mutex::new(()),
            rwlock: RwLock::new(()),
        }
    }

    /// Most keys a node may hold: M-1.
    pub fn max_keys(&self) -> usize {
        self.order - 1
    }

    /// Fewest keys a non-root node may hold: ceil(M/2)-1.
    pub fn min_keys(&self) -> usize {
        self.order.div_ceil(2) - 1
    }

    pub fn len(&self) -> usize {
        self.count.load(Ordering::Relaxed)
    }

    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }

    pub fn root(&self) -> NodeId {
        NodeId::from_raw(self.root.load(Ordering::Acquire))
    }

    pub(crate) fn set_root(&self, id: NodeId) {
        self.root.store(id.raw(), Ordering::Release);
    }

    pub fn get(&self, key: u64) -> Option<u64> {
        self.get_hooked(key, None)
    }

    /// Inserts or overwrites. Returns the previous value if the key existed.
    /// On `Err(OutOfNodes)` the tree is unchanged and no lock is held.
    pub fn put(&self, key: u64, value: u64) -> Result<Option<u64>, OutOfNodes> {
        self.put_hooked(key, value, None)
    }

    pub fn get_hooked(&self, key: u64, hook: Hook<'_>) -> Option<u64> {
        if self.protocol == Protocol::LatchCoupling {
            return coupled::get(self, key, hook);
        }
        let _guard = self.lock_global(Mode::Shared, hook);
        emit(hook, Point::AtLeaf, NodeId::NIL);
        plain::get(self, key)
    }

    pub fn put_hooked(
        &self,
        key: u64,
        value: u64,
        hook: Hook<'_>,
    ) -> Result<Option<u64>, OutOfNodes> {
        if self.protocol == Protocol::LatchCoupling {
            return coupled::put(self, key, value, hook);
        }
        let _guard = self.lock_global(Mode::Exclusive, hook);
        emit(hook, Point::AtLeaf, NodeId::NIL);
        plain::put(self, key, value, hook)
    }

    /// Takes the tree-wide lock. A mutex cannot tell readers from writers, so
    /// under `GlobalMutex` two `get`s exclude each other although neither
    /// changes anything; under `GlobalRwLock` they share the lock.
    fn lock_global(&self, mode: Mode, hook: Hook<'_>) -> GlobalGuard<'_> {
        let mut guard = GlobalGuard {
            _mutex: None,
            _shared: None,
            _exclusive: None,
        };
        match (self.protocol, mode) {
            (Protocol::GlobalMutex, _) => {
                guard._mutex = Some(acquire(
                    hook,
                    NodeId::NIL,
                    || self.mutex.try_lock(),
                    || self.mutex.lock().expect("lock poisoned"),
                ));
            }
            (Protocol::GlobalRwLock, Mode::Shared) => {
                guard._shared = Some(acquire(
                    hook,
                    NodeId::NIL,
                    || self.rwlock.try_read(),
                    || self.rwlock.read().expect("lock poisoned"),
                ));
            }
            (Protocol::GlobalRwLock, Mode::Exclusive) => {
                guard._exclusive = Some(acquire(
                    hook,
                    NodeId::NIL,
                    || self.rwlock.try_write(),
                    || self.rwlock.write().expect("lock poisoned"),
                ));
            }
            (Protocol::LatchCoupling, _) => unreachable!(),
        }
        guard
    }

    /// Number of levels (1 when the root is a leaf). Quiescent only.
    pub fn height(&self) -> usize {
        let mut levels = 1;
        let mut id = self.root();
        loop {
            let next = match &self.table.read(id).kind {
                Kind::Leaf(_) => return levels,
                Kind::Internal(internal) => internal.children[0],
            };
            id = next;
            levels += 1;
        }
    }

    /// True if no lock and no latch is held. Tests call it after every
    /// scenario: a latch leaked on an error path would otherwise show up
    /// only as a hang in some later test.
    pub fn nothing_locked(&self) -> bool {
        self.mutex.try_lock().is_ok()
            && self.rwlock.try_write().is_ok()
            && (0..self.table.capacity() as usize)
                .all(|i| self.table.latch(NodeId::from_index(i)).try_write().is_ok())
    }

    /// Handles of the nodes that somebody holds a latch on right now.
    /// Found by trying to latch every node exclusively. For tests.
    pub fn latched_nodes(&self) -> Vec<u32> {
        (0..self.table.capacity())
            .filter(|&i| {
                self.table
                    .latch(NodeId::from_index(i as usize))
                    .try_write()
                    .is_err()
            })
            .collect()
    }
}

/// Acquires a lock or latch. With a hook: try first, so that the hook hears
/// about the wait before it starts. Without: just wait.
pub(crate) fn acquire<G>(
    hook: Hook<'_>,
    node: NodeId,
    try_it: impl FnOnce() -> Result<G, TryLockError<G>>,
    wait: impl FnOnce() -> G,
) -> G {
    if hook.is_some() {
        match try_it() {
            Ok(guard) => return guard,
            Err(TryLockError::WouldBlock) => emit(hook, Point::Blocked, node),
            Err(TryLockError::Poisoned(_)) => panic!("lock poisoned"),
        }
    }
    wait()
}

/// A freshly reserved node, ready to be filled in.
pub(crate) fn fresh_node(tree: &Tree, id: NodeId, node: Node) -> RwLockWriteGuard<'_, Node> {
    // Nobody can reach `id` yet, so this latch is free and stays private
    // until the parent or the root pointer names the node.
    let mut guard = tree.table.write(id);
    *guard = node;
    guard
}
