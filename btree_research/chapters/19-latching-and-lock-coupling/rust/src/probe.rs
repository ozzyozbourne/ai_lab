//! Deterministic two-thread experiments, built on the test hook.
//!
//! An `Actor` is one operation running on its own thread. Its hook can FREEZE
//! it at a chosen point (it then keeps every lock and latch it holds there)
//! and it reports the first time it has to WAIT for somebody else's lock.
//!
//! `probe` uses two actors to answer one question without any sleep or
//! timing: "while operation A is frozen at this point, does operation B run
//! to completion, or does it get stuck, and on which node?"

use std::sync::{Condvar, Mutex};
use std::thread;

use crate::base_node::{NodeId, OutOfNodes};
use crate::tree::{Event, Point, Tree};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OpSpec {
    Get(u64),
    Put(u64),
}

impl OpSpec {
    pub fn key(self) -> u64 {
        match self {
            OpSpec::Get(key) | OpSpec::Put(key) => key,
        }
    }

    pub fn name(self) -> &'static str {
        match self {
            OpSpec::Get(_) => "get",
            OpSpec::Put(_) => "put",
        }
    }
}

/// The value every demo and test stores under `key`.
pub fn value_of(key: u64) -> u64 {
    key * 100
}

/// Where to freeze an actor: the first event with this point (and this node,
/// if one is given).
#[derive(Debug, Clone, Copy)]
pub struct Pause {
    pub point: Point,
    pub node: Option<NodeId>,
}

impl Pause {
    pub fn at(point: Point) -> Pause {
        Pause { point, node: None }
    }
}

/// A one-way flag with "wait until set" (Zig: `std.Io.Event`).
#[derive(Default)]
struct Gate {
    open: Mutex<bool>,
    changed: Condvar,
}

impl Gate {
    fn set(&self) {
        *self.open.lock().expect("gate poisoned") = true;
        self.changed.notify_all();
    }

    fn wait(&self) {
        let mut open = self.open.lock().expect("gate poisoned");
        while !*open {
            open = self.changed.wait(open).expect("gate poisoned");
        }
    }
}

#[derive(Default)]
struct Seen {
    frozen: bool,
    blocked_at: Option<NodeId>,
}

pub struct Actor<'t> {
    tree: &'t Tree,
    op: OpSpec,
    pause: Option<Pause>,
    /// Set when the actor is frozen, is about to wait for a lock, or is
    /// done: whichever comes first.
    settled: Gate,
    /// Set by the controlling thread to unfreeze the actor.
    go_on: Gate,
    seen: Mutex<Seen>,
}

impl<'t> Actor<'t> {
    pub fn new(tree: &'t Tree, op: OpSpec, pause: Option<Pause>) -> Actor<'t> {
        Actor {
            tree,
            op,
            pause,
            settled: Gate::default(),
            go_on: Gate::default(),
            seen: Mutex::new(Seen::default()),
        }
    }

    /// The body of the actor's thread: `scope.spawn(|| actor.run())`.
    pub fn run(&self) -> Result<Option<u64>, OutOfNodes> {
        let hook = |event: Event| self.on_event(event);
        let result = match self.op {
            OpSpec::Get(key) => Ok(self.tree.get_hooked(key, Some(&hook))),
            OpSpec::Put(key) => self.tree.put_hooked(key, value_of(key), Some(&hook)),
        };
        self.settled.set();
        result
    }

    /// Runs on the actor's thread, in the middle of its operation.
    fn on_event(&self, event: Event) {
        {
            let mut seen = self.seen.lock().expect("actor poisoned");
            if event.point == Point::Blocked {
                seen.blocked_at.get_or_insert(event.node);
                drop(seen);
                self.settled.set();
                return;
            }
            let Some(pause) = self.pause else { return };
            if seen.frozen || event.point != pause.point {
                return;
            }
            if pause.node.is_some_and(|node| node != event.node) {
                return;
            }
            seen.frozen = true;
        }
        self.settled.set();
        self.go_on.wait(); // frozen here, locks and all
    }

    pub fn wait_settled(&self) {
        self.settled.wait();
    }

    pub fn release(&self) {
        self.go_on.set();
    }

    pub fn frozen(&self) -> bool {
        self.seen.lock().expect("actor poisoned").frozen
    }

    pub fn blocked_at(&self) -> Option<NodeId> {
        self.seen.lock().expect("actor poisoned").blocked_at
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Outcome {
    /// B finished while A was still frozen.
    Completed,
    /// B had to wait for the lock or latch of this node (`NIL`: the
    /// tree-wide lock) and finished only after A was released.
    Blocked(NodeId),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ProbeError {
    PauseNotReached,
    OperationFailed,
}

/// Freezes `a` at `pause`, runs `b` on a second thread, and reports whether
/// `b` got through. Both operations have completed when this returns.
pub fn probe(tree: &Tree, a_op: OpSpec, pause: Pause, b_op: OpSpec) -> Result<Outcome, ProbeError> {
    let a = Actor::new(tree, a_op, Some(pause));
    let b = Actor::new(tree, b_op, None);
    thread::scope(|scope| {
        let a_thread = scope.spawn(|| a.run());
        a.wait_settled();
        if !a.frozen() {
            // A blocked or finished without ever reaching the pause point.
            a.release();
            a_thread.join().expect("actor panicked").ok();
            return Err(ProbeError::PauseNotReached);
        }

        let b_thread = scope.spawn(|| b.run());
        // B either finishes or reports that it must wait. If it waits, it
        // waits for something A holds, so it cannot finish before A is
        // released: the answer read here is final.
        b.wait_settled();
        let outcome = match b.blocked_at() {
            Some(node) => Outcome::Blocked(node),
            None => Outcome::Completed,
        };

        a.release();
        let a_result = a_thread.join().expect("actor panicked");
        let b_result = b_thread.join().expect("actor panicked");
        if a_result.is_err() || b_result.is_err() {
            return Err(ProbeError::OperationFailed);
        }
        Ok(outcome)
    })
}
