//! resumable.rs: `put` and `get` of the disk B+tree, rewritten so that they
//! never wait for the disk.
//!
//! The blocking `DiskBTree::put` calls `pool.fetch_page(id)`, and when the
//! page is not in memory that call sits inside `read()` until the disk
//! answers. Nothing else can run on that thread meanwhile. An engine that
//! serves many statements from one thread (Turso) cannot afford that, so its
//! B-tree code has this shape instead:
//!
//! ```text
//!     match op.step(&mut tree)? {
//!         Step::Done => ...        // finished
//!         Step::Io(page) => ...    // "I need this page. Call me again when
//!     }                            //  it is in the buffer pool."
//! ```
//!
//! `step` returns to its caller instead of waiting, which means its local
//! variables are gone when it is called again. Everything the operation needs
//! to remember must therefore live in the operation object: WHERE it stopped
//! (`State`, the blocking code's program counter) and the data that was live
//! at that point (the path, the carry of the last split).
//!
//! Difference from Zig. There `State` is a plain enum and the data sits in
//! fields of the operation, backed by one arena. Here the enum OWNS its data:
//! each variant carries exactly what is live in that state, as owned values
//! (`Carry` holds a `Vec<u8>`). Leaving a state moves the data out of it, so
//! a state cannot read what belongs to another one, and a slice into a
//! buffer that will not exist at the next call does not compile.
//!
//! The rules that make re-entry safe (they are Turso's rules, see
//! turso/docs/agent-guides/async-io-model.md:117-160):
//!
//!   R1  A step asks for its page FIRST and changes nothing before that.
//!       If the page is missing it returns `Io` having done nothing, so
//!       calling it again, with or without the page, repeats nothing.
//!   R2  Whatever a step changes (a page, the path, the carry) it changes
//!       after its last yield point, and it records the new state in the
//!       same breath. No change is ever made twice.
//!   R3  No page stays pinned across a yield: every step unpins what it
//!       pinned before it returns. An operation that is abandoned while it
//!       waits therefore leaves nothing behind in the pool.
//!
//! What `step` does NOT avoid: writes. `pool.new_page` writes a zero page to
//! grow the file and may write a dirty victim back. A complete engine yields
//! there too; this chapter stops at reads to stay small (exercise 4).

use crate::base_slotted_page::PageError;
use crate::disk_btree::{
    self as btree, Carry, DiskBTree, KIND_LEAF, PageId, PathEntry, TreeError, pin_node,
};

pub type Result<T> = std::result::Result<T, TreeError>;

/// What one call of `step` reports.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Step {
    /// The operation is complete.
    Done,
    /// The operation needs this page in the buffer pool. Nothing has been
    /// read: the caller arranges that, then calls `step` again.
    Io(PageId),
}

/// Where an insert is, and the data that is live there. Each of the first
/// seven states begins by asking for exactly one page, so each is one
/// possible suspension point.
#[derive(Debug)]
pub enum State {
    /// Walking down: look at `page`, an interior page or the leaf.
    Descend {
        page: PageId,
    },
    /// Put the cell into `leaf`, if it fits.
    LeafPut {
        leaf: PageId,
    },
    /// The full leaf is the root: move the root's content one level down.
    PushRootLeaf,
    /// Split `leaf` around the new cell.
    SplitLeaf {
        leaf: PageId,
    },
    /// Give `carry` to the parent on top of the path.
    InsertSeparator {
        carry: Carry,
    },
    /// The full parent is the root: move its content one level down.
    PushRootInterior {
        parent: PathEntry,
        carry: Carry,
    },
    /// Split interior page `parent` around the separator of `carry`.
    SplitInterior {
        parent: PathEntry,
        carry: Carry,
    },
    Done,
    Failed,
}

/// `State` without its data: for counting, comparing and printing.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StateKind {
    Descend,
    LeafPut,
    PushRootLeaf,
    SplitLeaf,
    InsertSeparator,
    PushRootInterior,
    SplitInterior,
    Done,
    Failed,
}

/// Number of states that can suspend (all but `Done` and `Failed`).
pub const SUSPEND_POINTS: usize = 7;

impl StateKind {
    pub const SUSPENDABLE: [StateKind; SUSPEND_POINTS] = [
        StateKind::Descend,
        StateKind::LeafPut,
        StateKind::PushRootLeaf,
        StateKind::SplitLeaf,
        StateKind::InsertSeparator,
        StateKind::PushRootInterior,
        StateKind::SplitInterior,
    ];

    /// The Zig spelling, so that both programs print the same text.
    pub fn name(self) -> &'static str {
        match self {
            StateKind::Descend => "descend",
            StateKind::LeafPut => "leaf_put",
            StateKind::PushRootLeaf => "push_root_leaf",
            StateKind::SplitLeaf => "split_leaf",
            StateKind::InsertSeparator => "insert_separator",
            StateKind::PushRootInterior => "push_root_interior",
            StateKind::SplitInterior => "split_interior",
            StateKind::Done => "done",
            StateKind::Failed => "failed",
        }
    }
}

impl State {
    pub fn kind(&self) -> StateKind {
        match self {
            State::Descend { .. } => StateKind::Descend,
            State::LeafPut { .. } => StateKind::LeafPut,
            State::PushRootLeaf => StateKind::PushRootLeaf,
            State::SplitLeaf { .. } => StateKind::SplitLeaf,
            State::InsertSeparator { .. } => StateKind::InsertSeparator,
            State::PushRootInterior { .. } => StateKind::PushRootInterior,
            State::SplitInterior { .. } => StateKind::SplitInterior,
            State::Done => StateKind::Done,
            State::Failed => StateKind::Failed,
        }
    }
}

/// Where the separator of a split is kept between two calls. `StepBuffer`
/// is the WRONG choice, kept to show what it does: see `leave_step`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum Scratch {
    /// In the state itself, as an owned `Vec<u8>` (Zig: in the op's arena).
    #[default]
    OpOwned,
    /// In a buffer that every call of `step` uses for its temporary data.
    StepBuffer,
}

#[derive(Debug, Clone, Copy, Default)]
pub struct Options {
    pub scratch: Scratch,
    /// Testing knob: between any two transitions, drop every unpinned page
    /// from the pool, the worst an eviction policy could do to us. It turns
    /// every state into an actual suspension. (Turso has the same kind of
    /// knob: `inject_io_yield!`, turso/core/storage/btree.rs:3312-3315.)
    pub pressure: bool,
}

/// One transition's outcome.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Advance {
    Again,
    Done,
    Io(PageId),
}

pub struct InsertOp {
    /// Owned copies: the caller's buffers need not outlive `new`, and
    /// usually do not, because the operation finishes many calls later.
    key: Vec<u8>,
    value: Vec<u8>,
    options: Options,
    state: State,
    /// The interior pages passed on the way down and the child index taken.
    path: Vec<PathEntry>,
    existed: bool,
    /// A page of the tree has been changed: failing now leaves it half-split.
    changed: bool,
    /// The page we last reported as missing, until we see it in the pool.
    waiting: Option<PageId>,
    /// How often each state returned `Io` (counted once per wait).
    pub suspended: [u32; SUSPEND_POINTS],
    pub resumptions: u32,
    /// `Scratch::StepBuffer` only: the per-call buffer and the length of the
    /// separator that was left in it.
    step_buf: Vec<u8>,
    sep_len: usize,
}

impl InsertOp {
    /// Start an insert of (key, value).
    pub fn new(tree: &DiskBTree, key: &[u8], value: &[u8], options: Options) -> Result<Self> {
        if tree.is_poisoned() {
            return Err(TreeError::TreePoisoned);
        }
        if key.len() > btree::MAX_KEY_LEN {
            return Err(TreeError::KeyTooLarge);
        }
        if value.len() > btree::MAX_VALUE_LEN {
            return Err(TreeError::ValueTooLarge);
        }
        Ok(Self {
            key: key.to_vec(),
            value: value.to_vec(),
            options,
            state: State::Descend { page: tree.root() },
            path: Vec::new(),
            existed: false,
            changed: false,
            waiting: None,
            suspended: [0; SUSPEND_POINTS],
            resumptions: 0,
            step_buf: Vec::new(),
            sep_len: 0,
        })
    }

    pub fn state(&self) -> &State {
        &self.state
    }

    pub fn kind(&self) -> StateKind {
        self.state.kind()
    }

    pub fn key(&self) -> &[u8] {
        &self.key
    }

    pub fn path_len(&self) -> usize {
        self.path.len()
    }

    pub fn has_changed_a_page(&self) -> bool {
        self.changed
    }

    pub fn finished(&self) -> bool {
        matches!(self.state, State::Done | State::Failed)
    }

    /// Heap bytes the operation holds for its key, value and path. Zero once
    /// it is done or has failed (Zig asks its arena the same question).
    pub fn held_bytes(&self) -> usize {
        self.key.capacity() + self.value.capacity() + self.path.capacity() + self.step_buf.len()
    }

    /// Run until the operation is complete or needs a page that is not in
    /// the pool. Never reads from the disk. On an error the operation is
    /// over (`Failed`), holds no pin and no memory, and has poisoned the
    /// tree if it had already changed a page.
    pub fn step(&mut self, tree: &mut DiskBTree) -> Result<Step> {
        assert!(!self.finished());
        let result = self.run(tree);
        if result.is_err() {
            self.fail(tree);
        }
        result
    }

    fn run(&mut self, tree: &mut DiskBTree) -> Result<Step> {
        if tree.is_poisoned() {
            return Err(TreeError::TreePoisoned);
        }
        loop {
            match self.advance(tree)? {
                // (Not before the first transition of a call: the page the
                // caller just supplied must still be there, or we would ask
                // for it for ever.)
                Advance::Again => {
                    if self.options.pressure {
                        tree.pool.evict_unpinned()?;
                    }
                }
                Advance::Done => return Ok(Step::Done),
                Advance::Io(id) => {
                    self.leave_step();
                    return Ok(Step::Io(id));
                }
            }
        }
    }

    /// The caller gives up on the operation (its read failed, or the
    /// statement was cancelled). Same end state as an error inside `step`.
    pub fn cancel(&mut self, tree: &mut DiskBTree) {
        if !self.finished() {
            self.fail(tree);
        }
    }

    /// R1 in one place: is the page missing from the pool? If so, count the
    /// suspension. `frame_of` only looks; it changes no statistics and no
    /// reference bits.
    fn missing(&mut self, tree: &DiskBTree, id: PageId, kind: StateKind) -> bool {
        if tree.pool.frame_of(id).is_some() {
            if self.waiting.is_some() {
                self.resumptions += 1;
            }
            self.waiting = None;
            return false;
        }
        if self.waiting.is_none() {
            self.suspended[kind as usize] += 1;
        }
        self.waiting = Some(id);
        true
    }

    /// One transition of the state machine. Public so that tests can stop
    /// between any two transitions; everyone else calls `step`.
    ///
    /// The state is TAKEN out of `self` (leaving `Failed` behind) and a new
    /// one is put in before returning. This is how a variant's owned data
    /// can be moved on to the next variant, and it is what Turso does too
    /// ("take() ... insert the state back if overwriting returns IO",
    /// turso/core/storage/btree.rs:3329-3331). Two consequences:
    ///   * a yield must put the SAME state back, untouched (R1);
    ///   * an error that leaves through `?` leaves `Failed` in place, which
    ///     is exactly what a failed operation should be.
    ///
    /// Every arm has the same three parts, in this order:
    ///   1. `missing`: put the state back and return `Io` (nothing done yet)
    ///   2. one all-or-nothing step of chapter 12's `put`; the page it
    ///      fetches is in the pool, so the fetch cannot block
    ///   3. record what was learned and the next state
    pub fn advance(&mut self, tree: &mut DiskBTree) -> Result<Advance> {
        match std::mem::replace(&mut self.state, State::Failed) {
            State::Descend { page: id } => {
                if self.missing(tree, id, StateKind::Descend) {
                    self.state = State::Descend { page: id };
                    return Ok(Advance::Io(id));
                }
                let page = pin_node(&mut tree.pool, id)?;
                if page.kind() == KIND_LEAF {
                    tree.pool.unpin(id, false);
                    self.state = State::LeafPut { leaf: id };
                    return Ok(Advance::Again);
                }
                let index = btree::child_index(&page, &self.key);
                let child = btree::child_at(&page, index);
                tree.pool.unpin(id, false);
                // The path grows AFTER the yield point above (R2). Had the
                // push come first, every re-entry would add the same page
                // again: the bug of async-io-model.md:162-169.
                self.path.push(PathEntry { id, index });
                self.state = State::Descend { page: child };
                Ok(Advance::Again)
            }
            State::LeafPut { leaf: id } => {
                if self.missing(tree, id, StateKind::LeafPut) {
                    self.state = State::LeafPut { leaf: id };
                    return Ok(Advance::Io(id));
                }
                let mut leaf = pin_node(&mut tree.pool, id)?;
                self.existed = leaf.search(&self.key).found;
                match leaf.put(&self.key, &self.value) {
                    Ok(()) => {
                        tree.pool.unpin(id, true);
                        Ok(self.finish(tree))
                    }
                    Err(PageError::CellTooLarge) => unreachable!("excluded in `new`"),
                    Err(PageError::PageFull) => {
                        tree.pool.unpin(id, false);
                        self.state = if self.path.is_empty() {
                            State::PushRootLeaf
                        } else {
                            State::SplitLeaf { leaf: id }
                        };
                        Ok(Advance::Again)
                    }
                }
            }
            State::PushRootLeaf => {
                let root = tree.root();
                if self.missing(tree, root, StateKind::PushRootLeaf) {
                    self.state = State::PushRootLeaf;
                    return Ok(Advance::Io(root));
                }
                let leaf = tree.push_root_down()?;
                self.changed = true;
                self.path.push(PathEntry { id: root, index: 0 });
                self.state = State::SplitLeaf { leaf };
                Ok(Advance::Again)
            }
            State::SplitLeaf { leaf } => {
                if self.missing(tree, leaf, StateKind::SplitLeaf) {
                    self.state = State::SplitLeaf { leaf };
                    return Ok(Advance::Io(leaf));
                }
                // The separator in `carry` is read by the NEXT state,
                // possibly many calls from now. It is an owned Vec, so it
                // simply moves into that state.
                let carry = tree.split_leaf(leaf, &self.key, &self.value)?;
                self.changed = true;
                self.state = State::InsertSeparator {
                    carry: self.stash(carry),
                };
                Ok(Advance::Again)
            }
            State::InsertSeparator { mut carry } => {
                // Look at the top of the path but do not pop it yet: if we
                // yield here, the entry must still be there on re-entry.
                let parent = *self.path.last().expect("a split page has a parent");
                if self.missing(tree, parent.id, StateKind::InsertSeparator) {
                    self.state = State::InsertSeparator { carry };
                    return Ok(Advance::Io(parent.id));
                }
                self.unstash(&mut carry);
                let fitted = tree.insert_separator(parent, &carry)?;
                self.path.pop();
                if fitted {
                    return Ok(self.finish(tree));
                }
                let carry = self.stash(carry);
                self.state = if self.path.is_empty() {
                    State::PushRootInterior { parent, carry }
                } else {
                    State::SplitInterior { parent, carry }
                };
                Ok(Advance::Again)
            }
            State::PushRootInterior { mut parent, carry } => {
                let root = tree.root();
                if self.missing(tree, root, StateKind::PushRootInterior) {
                    self.state = State::PushRootInterior { parent, carry };
                    return Ok(Advance::Io(root));
                }
                // The child index stays valid: the cells moved unchanged.
                parent.id = tree.push_root_down()?;
                self.path.push(PathEntry { id: root, index: 0 });
                self.state = State::SplitInterior { parent, carry };
                Ok(Advance::Again)
            }
            State::SplitInterior { parent, mut carry } => {
                if self.missing(tree, parent.id, StateKind::SplitInterior) {
                    self.state = State::SplitInterior { parent, carry };
                    return Ok(Advance::Io(parent.id));
                }
                self.unstash(&mut carry);
                let up = tree.split_interior(parent, &carry)?;
                self.state = State::InsertSeparator {
                    carry: self.stash(up),
                };
                Ok(Advance::Again)
            }
            State::Done | State::Failed => unreachable!("stepped after the end"),
        }
    }

    /// `Scratch::StepBuffer`: move the separator out of the state and into
    /// the per-call buffer, remembering only its length. The state now holds
    /// an "index into a buffer", the shape a dangling reference takes in
    /// safe Rust.
    ///
    /// (A separator that IS the new key stays where it is. In Zig that
    /// separator is a slice of the operation's own key, not of the scratch
    /// buffer, and survives; the two programs must break at the same insert.)
    fn stash(&mut self, mut carry: Carry) -> Carry {
        if self.options.scratch == Scratch::StepBuffer && carry.sep != self.key {
            self.sep_len = carry.sep.len();
            if self.step_buf.len() < self.sep_len {
                self.step_buf.resize(self.sep_len, 0);
            }
            self.step_buf[..self.sep_len].copy_from_slice(&carry.sep);
            carry.sep.clear();
        }
        carry
    }

    fn unstash(&self, carry: &mut Carry) {
        if self.options.scratch == Scratch::StepBuffer && carry.sep.is_empty() {
            carry.sep = self.step_buf[..self.sep_len].to_vec();
        }
    }

    /// Called when `step` is about to return `Io`.
    ///
    /// With `OpOwned` there is nothing to do. With `StepBuffer` the buffer
    /// is treated the way a stack frame is treated when its function
    /// returns: it is given up, and the next user overwrites it. (0xAA is
    /// what Zig's Debug mode writes into memory that became undefined.) The
    /// length kept in `sep_len` still refers to it.
    fn leave_step(&mut self) {
        if self.options.scratch == Scratch::StepBuffer {
            self.step_buf.fill(0xAA);
        }
    }

    fn finish(&mut self, tree: &mut DiskBTree) -> Advance {
        if !self.existed {
            tree.key_count += 1;
        }
        self.state = State::Done;
        self.release();
        Advance::Done
    }

    fn fail(&mut self, tree: &mut DiskBTree) {
        if self.changed {
            tree.poisoned = true;
        }
        self.state = State::Failed;
        self.release();
    }

    /// Give the memory back now, not when the handle is dropped. (Assigning
    /// `State::Done` or `Failed` above already dropped whatever the old
    /// state owned.)
    fn release(&mut self) {
        self.key = Vec::new();
        self.value = Vec::new();
        self.path = Vec::new();
        self.step_buf = Vec::new();
    }
}

/// A resumable point lookup: the same descent, read-only. It exists so that
/// the scheduler has operations whose reads may interleave.
pub struct GetOp {
    key: Vec<u8>,
    cur: PageId,
    done: bool,
    /// The answer, an owned copy, valid once `step` returned `Done`.
    pub value: Option<Vec<u8>>,
    waiting: Option<PageId>,
    pub suspended: u32,
}

impl GetOp {
    pub fn new(tree: &DiskBTree, key: &[u8]) -> Result<Self> {
        if tree.is_poisoned() {
            return Err(TreeError::TreePoisoned);
        }
        Ok(Self {
            key: key.to_vec(),
            cur: tree.root(),
            done: false,
            value: None,
            waiting: None,
            suspended: 0,
        })
    }

    pub fn step(&mut self, tree: &mut DiskBTree) -> Result<Step> {
        assert!(!self.done);
        if tree.is_poisoned() {
            return Err(TreeError::TreePoisoned);
        }
        loop {
            let id = self.cur;
            if tree.pool.frame_of(id).is_none() {
                if self.waiting.is_none() {
                    self.suspended += 1;
                }
                self.waiting = Some(id);
                return Ok(Step::Io(id));
            }
            self.waiting = None;
            let page = pin_node(&mut tree.pool, id)?;
            if page.kind() == KIND_LEAF {
                // Copy the value out: the page may be evicted as soon as it
                // is unpinned, long before the caller looks at the answer.
                self.value = page.get(&self.key).map(<[u8]>::to_vec);
                tree.pool.unpin(id, false);
                self.done = true;
                return Ok(Step::Done);
            }
            self.cur = btree::child_at(&page, btree::child_index(&page, &self.key));
            tree.pool.unpin(id, false);
        }
    }
}
