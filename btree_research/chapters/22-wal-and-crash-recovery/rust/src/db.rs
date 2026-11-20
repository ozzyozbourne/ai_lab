//! db.rs: the disk tree of chapter 12 behind the write-ahead log.
//!
//! ```text
//! Db::open     recover (replay the log), then open the tree, or create it
//!              if the files are empty
//! Db::put      tree.put, then tree.flush. `flush` writes the dirty pages
//!              and the metapage to the storage and syncs it; the storage is
//!              the `Wal`, whose sync is a commit. When `put` returns, the
//!              key is durable. A checkpoint follows every few commits.
//! Db::put_batch  several puts, ONE commit: all of them or none of them.
//! ```
//!
//! Nothing in the tree, the buffer pool or the pager changed for this: the
//! log was slid in underneath, at the one interface they all share.
//!
//! An error from `put` means "outcome unknown", not "not stored": the power
//! may have failed after the commit record became durable but before `put`
//! could return. After such an error the handle must be dropped and the
//! database reopened; recovery then decides. The handle enforces this: once
//! `put`, `put_batch` or `checkpoint` has failed after it started to change
//! something, every later call returns `DbError::ReopenRequired`. Without
//! that, the pages a failed operation left in memory would be committed by
//! the next successful one. The one error that leaves the handle usable is a
//! key or value that is too long: it is found before anything is touched.

use std::cell::RefCell;
use std::rc::Rc;

use crate::base_buffer_pool::BufferPool;
use crate::base_disk_btree::{DiskBTree, MAX_KEY_LEN, MAX_VALUE_LEN, RangeIterator, TreeError};
use crate::base_page_storage::Storage as PageStorage;
use crate::base_pager::Pager;
use crate::wal::{self, Recovery, Wal, WalError, WalStorage};

#[derive(Debug, Clone, Copy)]
pub struct Options {
    /// Buffer pool size, at least 1 (the pool asserts it). 2 is enough:
    /// evicted dirty pages go to the log layer.
    pub frames: usize,
    /// Checkpoint when this many commits are in the log. 0 = never.
    pub checkpoint_every: u32,
    pub max_commit_pages: u32,
}

impl Default for Options {
    fn default() -> Self {
        Self {
            frames: 8,
            checkpoint_every: 4,
            max_commit_pages: 32,
        }
    }
}

/// Zig merges the two error sets with `||`; here they are wrapped.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DbError {
    Tree(TreeError),
    Wal(WalError),
    /// An earlier operation on this handle failed. Drop it and open the
    /// database again; recovery decides what was stored.
    ReopenRequired,
}

impl From<TreeError> for DbError {
    fn from(e: TreeError) -> Self {
        DbError::Tree(e)
    }
}

impl From<WalError> for DbError {
    fn from(e: WalError) -> Self {
        DbError::Wal(e)
    }
}

pub struct Db {
    options: Options,
    /// The tree owns the pool, which owns the pager, which owns a handle to
    /// the log. This is the second handle. (Zig: one struct on the heap whose
    /// parts point at each other.)
    wal: Rc<RefCell<Wal>>,
    pub tree: DiskBTree,
    /// What recovery found when this handle was opened.
    pub recovery: Recovery,
    /// Set when an operation failed half-way: the buffer pool and the log
    /// layer may hold pages of an operation that never committed.
    failed: bool,
}

impl Db {
    pub fn open(
        main: Box<dyn PageStorage>,
        log: Box<dyn PageStorage>,
        options: Options,
    ) -> Result<Self, DbError> {
        let wal_options = wal::Options {
            max_commit_pages: options.max_commit_pages,
        };
        let wal = Rc::new(RefCell::new(Wal::new(main, log, wal_options)));
        let recovery = wal.borrow_mut().recover()?;
        let pager = Pager::new(Box::new(WalStorage(Rc::clone(&wal)))).map_err(TreeError::from)?;
        let pool = BufferPool::new(pager, options.frames);
        // No pages at all: a new database, or one whose creation never
        // committed. Creating it is itself a logged, committed operation.
        let tree = if pool.pager().page_count() == 0 {
            DiskBTree::create(pool)?
        } else {
            DiskBTree::open(pool)?
        };
        Ok(Self {
            options,
            wal,
            tree,
            recovery,
            failed: false,
        })
    }

    /// Insert or overwrite one key. Atomic and durable at return.
    pub fn put(&mut self, key: &[u8], value: &[u8]) -> Result<(), DbError> {
        self.put_batch(&[(key, value)])
    }

    /// Insert or overwrite several keys as one operation with one commit
    /// record: after a crash either all of them are there or none.
    pub fn put_batch(&mut self, pairs: &[(&[u8], &[u8])]) -> Result<(), DbError> {
        self.check_usable()?;
        // Refuse a pair the tree would refuse BEFORE the first one is
        // applied: the tree has no undo, so a batch that stops in the middle
        // cannot be taken back.
        for (key, value) in pairs {
            if key.len() > MAX_KEY_LEN {
                return Err(TreeError::KeyTooLarge.into());
            }
            if value.len() > MAX_VALUE_LEN {
                return Err(TreeError::ValueTooLarge.into());
            }
        }
        // From here on an error leaves uncommitted pages behind.
        let result = self.apply_and_commit(pairs);
        self.failed = result.is_err();
        result
    }

    /// Zig does this inline under an `errdefer`; here the caller looks at
    /// the result.
    fn apply_and_commit(&mut self, pairs: &[(&[u8], &[u8])]) -> Result<(), DbError> {
        for (key, value) in pairs {
            self.tree.put(key, value)?;
        }
        self.commit()
    }

    fn commit(&mut self) -> Result<(), DbError> {
        // flush = write the metapage and every dirty page, then sync. The
        // writes land in the Wal's pending table; the sync is `Wal::commit`.
        self.tree.flush()?;
        let mut wal = self.wal.borrow_mut();
        if self.options.checkpoint_every != 0 && wal.commits_in_log >= self.options.checkpoint_every
        {
            wal.checkpoint()?;
        }
        Ok(())
    }

    pub fn checkpoint(&mut self) -> Result<(), DbError> {
        self.check_usable()?;
        let result = self.wal.borrow_mut().checkpoint();
        self.failed = result.is_err();
        Ok(result?)
    }

    fn check_usable(&self) -> Result<(), DbError> {
        if self.failed {
            return Err(DbError::ReopenRequired);
        }
        Ok(())
    }

    pub fn get(&mut self, key: &[u8]) -> Result<Option<Vec<u8>>, DbError> {
        self.check_usable()?; // it would show uncommitted pages
        Ok(self.tree.get(key)?)
    }

    pub fn range(&mut self, lo: &[u8], hi: Option<&[u8]>) -> Result<RangeIterator<'_>, DbError> {
        self.check_usable()?;
        Ok(self.tree.range(lo, hi)?)
    }

    pub fn validate(&mut self) -> Result<(), DbError> {
        self.check_usable()?;
        Ok(self.tree.validate()?)
    }

    /// Did an operation fail half-way? Then only a reopen helps.
    pub fn is_failed(&self) -> bool {
        self.failed
    }

    /// A look at the log layer: counters, generation, the last flattened error.
    pub fn wal(&self) -> std::cell::Ref<'_, Wal> {
        self.wal.borrow()
    }
}
