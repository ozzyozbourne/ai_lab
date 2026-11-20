//! scheduler.rs: the two things a resumable operation needs around it.
//!
//!   SimDisk    a "disk" whose reads complete LATER, in a seeded pseudo-random
//!              order. Submitting a read returns at once; `complete_one`
//!              picks one pending request and only then moves the bytes into
//!              the buffer pool. This is the only place in the chapter where
//!              a page is read.
//!   Scheduler  a cooperative scheduler on one thread: it steps operations
//!              until they yield, hands their requests to the disk, and wakes
//!              each one when its page has arrived.
//!
//! Who may run together. Reads of DIFFERENT lookups interleave freely: the
//! scheduler admits any number of `get`s at once and their page requests
//! complete in whatever order the disk likes. A writer runs ALONE: an insert
//! is admitted only when nothing else is in flight, and nothing else is
//! admitted until it is done. The reason is visible in this very tree: an
//! insert that yields between `split_leaf` and `insert_separator` has left a
//! leaf whose right half no parent points to yet. A reader let in at that
//! moment would descend into the left half and miss keys that exist
//! (tests.rs shows it happen). PostgreSQL solves this inside the tree, with
//! right links and high keys (chapter 20), and lets writers overlap. Turso
//! keeps the tree simple and solves it outside: one write transaction at a
//! time (turso/core/storage/wal.rs:3587-3589), while readers look at the
//! snapshot in the WAL instead of the writer's dirty pages (chapter 22).
//! This file does the cruder thing and makes readers wait for the writer.
//!
//! Operations are admitted in the order they were submitted, so the result
//! is the one a blocking program would get by running them one by one.
//!
//! Difference from Zig: the operations do not hold a pointer to the tree
//! (two `&mut` to it could not coexist); the scheduler owns the one mutable
//! borrow and lends it to whichever operation it steps.

use crate::base_buffer_pool::BufferPool;
use crate::base_storage::Error as IoError;
use crate::disk_btree::{DiskBTree, INVALID_PAGE_ID, PageId, TreeError};
use crate::prng::SplitMix64;
use crate::resumable::{GetOp, InsertOp, Options, SUSPEND_POINTS, Step};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Request {
    pub op: usize,
    pub page: PageId,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Completion {
    pub op: usize,
    pub page: PageId,
    pub err: Option<IoError>,
}

pub struct SimDisk {
    rng: SplitMix64,
    pending: Vec<Request>,
    /// Requests completed.
    pub completions: u64,
}

impl SimDisk {
    pub fn new(seed: u64) -> Self {
        Self {
            rng: SplitMix64::new(seed),
            pending: Vec::new(),
            completions: 0,
        }
    }

    pub fn pending(&self) -> usize {
        self.pending.len()
    }

    /// Queue a read. Returns immediately; nothing is read yet.
    pub fn submit(&mut self, op: usize, page: PageId) {
        self.pending.push(Request { op, page });
    }

    /// Complete one pending read, chosen pseudo-randomly: the page is read
    /// into the buffer pool and left there unpinned. This call stands for the
    /// kernel (or an I/O thread) finishing a request while the database
    /// thread was doing something else.
    pub fn complete_one(&mut self, pool: &mut BufferPool) -> Completion {
        assert!(!self.pending.is_empty());
        let i = self.rng.below(self.pending.len() as u64) as usize;
        let req = self.pending.remove(i);
        self.completions += 1;
        let err = match pool.fetch_page(req.page) {
            Ok(_) => {
                pool.unpin(req.page, false);
                None
            }
            Err(e) => Some(e),
        };
        Completion {
            op: req.op,
            page: req.page,
            err,
        }
    }
}

pub enum Op {
    Insert(InsertOp),
    Get(GetOp),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Status {
    Queued,
    Waiting,
    Done,
    Failed,
}

pub struct Slot {
    pub op: Op,
    pub status: Status,
    pub err: Option<TreeError>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EventKind {
    Admit,
    Yield,
    Complete,
    Done,
    Failed,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Event {
    pub kind: EventKind,
    pub op: usize,
    pub page: PageId,
}

pub struct Scheduler<'a> {
    tree: &'a mut DiskBTree,
    pub disk: SimDisk,
    pub slots: Vec<Slot>,
    /// Slots before this index have been admitted.
    admitted: usize,
    readers_in_flight: u32,
    writer_in_flight: bool,
    pub insert_options: Options,
    /// `step` calls made, and how many of them returned `Io`.
    pub steps: u64,
    pub yields: u64,
    /// Suspensions of finished inserts, by state.
    pub suspended: [u64; SUSPEND_POINTS],
    /// When `Some`, every scheduling decision is appended (for the demo).
    pub events: Option<Vec<Event>>,
}

impl<'a> Scheduler<'a> {
    pub fn new(tree: &'a mut DiskBTree, seed: u64) -> Self {
        Self {
            tree,
            disk: SimDisk::new(seed),
            slots: Vec::new(),
            admitted: 0,
            readers_in_flight: 0,
            writer_in_flight: false,
            insert_options: Options::default(),
            steps: 0,
            yields: 0,
            suspended: [0; SUSPEND_POINTS],
            events: None,
        }
    }

    /// Queue an insert; returns its ticket.
    pub fn submit_insert(&mut self, key: &[u8], value: &[u8]) -> Result<usize, TreeError> {
        let op = InsertOp::new(self.tree, key, value, self.insert_options)?;
        Ok(self.push(Op::Insert(op)))
    }

    pub fn submit_get(&mut self, key: &[u8]) -> Result<usize, TreeError> {
        let op = GetOp::new(self.tree, key)?;
        Ok(self.push(Op::Get(op)))
    }

    fn push(&mut self, op: Op) -> usize {
        self.slots.push(Slot {
            op,
            status: Status::Queued,
            err: None,
        });
        self.slots.len() - 1
    }

    /// The answer of a finished `get`.
    pub fn result(&self, ticket: usize) -> Option<&[u8]> {
        assert_eq!(self.slots[ticket].status, Status::Done);
        match &self.slots[ticket].op {
            Op::Get(op) => op.value.as_deref(),
            Op::Insert(_) => panic!("ticket {ticket} is an insert"),
        }
    }

    /// Run every submitted operation to its end. An operation that fails is
    /// marked `Failed` with its error; the others go on.
    pub fn run(&mut self) {
        loop {
            self.admit();
            if self.disk.pending() == 0 {
                break;
            }
            // Nothing can run: every admitted operation waits for a page.
            let c = self.disk.complete_one(&mut self.tree.pool);
            self.note(EventKind::Complete, c.op, c.page);
            match c.err {
                Some(err) => {
                    if let Op::Insert(op) = &mut self.slots[c.op].op {
                        op.cancel(self.tree);
                    }
                    self.retire(c.op, Some(TreeError::Io(err)));
                }
                // Wake the operation NOW, before any other completion can
                // push its page out of a small pool again. This is what
                // guarantees progress: every completed read is followed by
                // at least one transition of the operation that asked.
                None => self.drive(c.op),
            }
        }
        assert_eq!(self.admitted, self.slots.len());
        assert!(self.readers_in_flight == 0 && !self.writer_in_flight);
    }

    /// Admit queued operations in submission order while the rule allows:
    /// readers share, a writer is alone.
    fn admit(&mut self) {
        while self.admitted < self.slots.len() {
            if self.writer_in_flight {
                return;
            }
            let i = self.admitted;
            match self.slots[i].op {
                Op::Get(_) => self.readers_in_flight += 1,
                Op::Insert(_) => {
                    if self.readers_in_flight > 0 {
                        return;
                    }
                    self.writer_in_flight = true;
                }
            }
            self.admitted += 1;
            self.note(EventKind::Admit, i, INVALID_PAGE_ID);
            self.drive(i);
        }
    }

    /// Step operation `i` once: it runs until it is done or needs a page.
    fn drive(&mut self, i: usize) {
        let reads_before = self.tree.pool.pager().stats.reads;
        let outcome = match &mut self.slots[i].op {
            Op::Insert(op) => op.step(self.tree),
            Op::Get(op) => op.step(self.tree),
        };
        self.steps += 1;
        // The two promises of a resumable operation, checked on every call:
        assert_eq!(self.tree.pool.pager().stats.reads, reads_before); // it read nothing
        assert_eq!(self.tree.pool.pinned_frames(), 0); // it kept no pin (R3)
        match outcome {
            Err(err) => self.retire(i, Some(err)),
            Ok(Step::Done) => self.retire(i, None),
            Ok(Step::Io(page)) => {
                self.yields += 1;
                self.slots[i].status = Status::Waiting;
                self.disk.submit(i, page);
                self.note(EventKind::Yield, i, page);
            }
        }
    }

    fn retire(&mut self, i: usize, err: Option<TreeError>) {
        let slot = &mut self.slots[i];
        slot.status = if err.is_none() { Status::Done } else { Status::Failed };
        slot.err = err;
        match &slot.op {
            Op::Get(_) => self.readers_in_flight -= 1,
            Op::Insert(op) => {
                self.writer_in_flight = false;
                for (total, n) in self.suspended.iter_mut().zip(op.suspended) {
                    *total += u64::from(n);
                }
            }
        }
        let kind = if err.is_none() { EventKind::Done } else { EventKind::Failed };
        self.note(kind, i, INVALID_PAGE_ID);
    }

    fn note(&mut self, kind: EventKind, op: usize, page: PageId) {
        if let Some(events) = &mut self.events {
            events.push(Event { kind, op, page });
        }
    }
}
