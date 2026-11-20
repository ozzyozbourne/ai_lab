//! Deterministic two-thread experiments, built on the test hook.
//!
//! An `Actor` is one operation running on its own thread. Its hook can FREEZE
//! it at a chosen point (it then keeps every lock and latch it holds there)
//! and it reports the first time it has to WAIT for somebody else's lock.
//!
//! `probe` uses two actors to answer one question without any sleep or
//! timing: "while operation A is frozen at this point, does operation B run
//! to completion, or does it get stuck, and on which node?"
//!
//! `convoy` asks the same about several operations started one after the
//! other behind the frozen one.
const std = @import("std");
const Io = std.Io;

const tree_ = @import("tree.zig");
const Tree = tree_.Tree;
const NodeId = tree_.NodeId;
const Hook = tree_.Hook;

pub const OpSpec = union(enum) { get: u64, put: u64 };

/// The value every demo and test stores under `key`.
pub fn valueOf(key: u64) u64 {
    return key * 100;
}

/// Where to freeze an actor: the first event with this point (and this node,
/// if one is given).
pub const Pause = struct { point: Hook.Point, node: ?NodeId = null };

pub const Actor = struct {
    tree: *Tree,
    io: Io,
    op: OpSpec,
    pause: ?Pause = null,

    /// Set when the actor is frozen, is about to wait for a lock, or is done:
    /// whichever comes first. Whoever waits for it then reads the fields
    /// below, which were written before the event was set.
    settled: Io.Event = .unset,
    /// Set by the controlling thread to unfreeze the actor.
    go_on: Io.Event = .unset,
    frozen: bool = false,
    blocked_at: ?NodeId = null,
    /// Valid after `join`.
    result: tree_.Error!?u64 = null,
    thread: std.Thread = undefined,

    pub fn spawn(self: *Actor) std.Thread.SpawnError!void {
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    fn run(self: *Actor) void {
        const hook: Hook = .{ .ctx = self, .func = onEvent };
        self.result = switch (self.op) {
            .get => |key| self.tree.getHooked(self.io, key, &hook),
            .put => |key| self.tree.putHooked(self.io, key, valueOf(key), &hook),
        };
        self.settled.set(self.io);
    }

    /// Runs on the actor's thread, in the middle of its operation.
    fn onEvent(ctx: *anyopaque, event: Hook.Event) void {
        const self: *Actor = @ptrCast(@alignCast(ctx));
        if (event.point == .blocked) {
            if (self.blocked_at == null) self.blocked_at = event.node;
            self.settled.set(self.io);
            return;
        }
        const pause = self.pause orelse return;
        if (self.frozen or event.point != pause.point) return;
        if (pause.node != null and pause.node.? != event.node) return;
        self.frozen = true;
        self.settled.set(self.io);
        self.go_on.waitUncancelable(self.io); // frozen here, locks and all
    }

    pub fn waitSettled(self: *Actor) void {
        self.settled.waitUncancelable(self.io);
    }

    pub fn release(self: *Actor) void {
        self.go_on.set(self.io);
    }

    pub fn join(self: *Actor) void {
        self.thread.join();
    }
};

pub const Outcome = union(enum) {
    /// B finished while A was still frozen.
    completed,
    /// B had to wait for the lock or latch of this node (`.nil`: the
    /// tree-wide lock) and finished only after A was released.
    blocked: NodeId,
};

pub const ProbeError = error{ PauseNotReached, OperationFailed } || std.Thread.SpawnError;

/// Freezes `a` at `pause`, runs `b` on a second thread, and reports whether
/// `b` got through. Both operations have completed when this returns.
///
/// B either finishes or reports that it must wait. If it waits, it waits for
/// something the frozen A holds, so it cannot finish before A is released:
/// the answer is final.
pub fn probe(tree: *Tree, io: Io, a_op: OpSpec, pause: Pause, b_op: OpSpec) ProbeError!Outcome {
    var outcome: [1]Outcome = undefined;
    try convoy(tree, io, a_op, pause, &.{b_op}, &outcome);
    return outcome[0];
}

/// Most operations `convoy` can start behind the frozen one.
pub const max_followers = 6;

/// `probe` with more than two threads. Freezes `first` at `pause`, then
/// starts `others` ONE AT A TIME: each is started only after the one before
/// it has finished or has reported that it must wait. `outcomes[i]` is what
/// happened to `others[i]`. Then `first` is released and every thread is
/// joined, so all operations have completed when this returns.
///
/// A follower that waits keeps the latches it already holds, so a later
/// follower can get stuck behind an EARLIER FOLLOWER and not behind `first`.
/// That is the convoy the chapter describes.
///
/// CAVEAT. `blocked` means "the try-lock failed". While only held latches are
/// in the way, that is a fact about the tree and the outcome is the same in
/// every run. But once a follower waits for an EXCLUSIVE latch on a node,
/// what a later reader of that node sees is no longer determined: the
/// follower reports `blocked` a moment BEFORE it enters the lock's queue,
/// and a writer-preferring lock (`std.Io.RwLock` is one) turns new readers
/// away only once the writer is queued. So put a follower that will wait
/// for an exclusive latch LAST among those that touch the same node.
pub fn convoy(tree: *Tree, io: Io, first: OpSpec, pause: Pause, others: []const OpSpec, outcomes: []Outcome) ProbeError!void {
    std.debug.assert(others.len == outcomes.len and others.len <= max_followers);
    var a: Actor = .{ .tree = tree, .io = io, .op = first, .pause = pause };
    // The threads hold pointers into this array: it must not move.
    var followers: [max_followers]Actor = undefined;

    try a.spawn();
    a.waitSettled();
    if (!a.frozen) {
        // A blocked or finished without ever reaching the pause point.
        a.release();
        a.join();
        return error.PauseNotReached;
    }

    var started: usize = 0;
    var spawn_error: ?std.Thread.SpawnError = null;
    for (others, outcomes) |op, *outcome| {
        const b = &followers[started];
        b.* = .{ .tree = tree, .io = io, .op = op };
        b.spawn() catch |err| {
            spawn_error = err;
            break;
        };
        started += 1;
        b.waitSettled();
        outcome.* = if (b.blocked_at) |node| .{ .blocked = node } else .completed;
    }

    // Whatever happened: release and join every thread that was started.
    a.release();
    a.join();
    for (followers[0..started]) |*b| b.join();
    if (spawn_error) |err| return err;
    _ = a.result catch return error.OperationFailed;
    for (followers[0..started]) |*b| _ = b.result catch return error.OperationFailed;
}
