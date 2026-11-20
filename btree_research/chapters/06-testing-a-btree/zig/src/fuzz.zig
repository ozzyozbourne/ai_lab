//! The model-based fuzzer.
//!
//!   swarm(seed)      -> Case     one seed decides the whole test: how many
//!                                steps, how many distinct keys, the mix of
//!                                operations, whether allocations fail
//!   generate(case)   -> []Step   the operations, as plain data
//!   replay(steps)    -> ?Failure run them against the tree AND a trivially
//!                                correct oracle; stop at the first difference
//!   hunt(seeds)      -> ?Found   replay one swarm case per seed, stop at the
//!                                first failure (huntShortest: try them all).
//!                                A case that passes is replayed once more
//!                                with other bytes in its freed nodes
//!
//! Operations are data, generated up front and replayed afterwards (never
//! "draw a random number, act on it immediately"). That is what makes a
//! failure reproducible from its seed, and what lets minimize.zig delete
//! steps from a failing sequence and run it again.
//!
//! `replay` is generic over the tree type, so the same harness tests the
//! correct tree at every order and each broken variant (base_btree.zig, `Bug`).
//!
//! A bug that corrupts the tree ends as a `Failure` with a step number. A bug
//! that trips an assert or a bounds check inside the tree ABORTS the process
//! before any check runs, and takes the seed with it. For that case there is
//! a trace mode: `zig build test -Dtrace=true` prints the seed and every step
//! to stderr BEFORE it runs, so the last lines before the panic name the case
//! (README, "When the tree crashes instead").
const std = @import("std");
const Allocator = std.mem.Allocator;
const ops = @import("ops.zig");
const SplitMix64 = @import("prng.zig").SplitMix64;
const validation = @import("base_validate.zig");
const Coverage = @import("coverage.zig").Coverage;
const FaultAllocator = @import("fault_alloc.zig").FaultAllocator;

/// Set by `zig build test -Dtrace=true` / `zig build run -Dtrace=true`.
pub const trace = @import("build_options").trace;
/// The seed `hunt` is replaying right now. Only the trace lines read it.
threadlocal var trace_seed: ?u64 = null;

/// One line on stderr, written BEFORE the step runs: if the tree aborts
/// inside the step, this is the last line and it names the case.
///   trace: seed 1, M=3, bug none, step 2 of 294: delete 3746994889972252672
///
/// `hunt` replays a passing case a second time with a different byte in
/// freed nodes; those lines end in "(freed nodes hold 0x01)".
fn traceStep(order: usize, bug: []const u8, index: usize, total: usize, step: Step, poison: u8) void {
    const note = if (poison == first_poison) "" else " (freed nodes hold 0x01)";
    if (trace_seed) |seed| {
        std.debug.print("trace: seed {d}, M={d}, bug {s}, step {d} of {d}: {f}{s}\n", .{ seed, order, bug, index + 1, total, step, note });
    } else {
        std.debug.print("trace: no seed (steps given directly), M={d}, bug {s}, step {d} of {d}: {f}{s}\n", .{ order, bug, index + 1, total, step, note });
    }
}

/// One operation, plus an optional round of injected faults. A put with
/// `fault` set is first tried with its node allocation 0 failing, then with
/// allocation 1 failing, and so on until it gets through: every allocation
/// the put makes fails once, down to the last node of the deepest
/// reservation. Only puts allocate.
pub const Step = struct {
    op: ops.Op,
    fault: bool = false,

    /// Printed with `{f}`: `put 7 = 70`, `delete 7`, `get 7`, `range [3, 9)`.
    pub fn format(self: Step, w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self.op) {
            .put => |p| try w.print("put {d} = {d}", .{ p.key, p.value }),
            .delete => |d| try w.print("delete {d}", .{d.key}),
            .get => |g| try w.print("get {d}", .{g.key}),
            .range => |r| try w.print("range [{d}, {d})", .{ r.lo, r.hi }),
        }
        if (self.fault) try w.writeAll(" (each node allocation fails once first)");
    }
};

/// Where in the 64-bit key space the keys of a case lie. The operation
/// stream draws a small index k in [0, key_space); the layout turns it into
/// the key. All four are strictly increasing in k, so the SHAPE of the tree
/// is the same whichever is chosen; what changes is the numbers the tree has
/// to compare. A tree that truncates a key to 32 bits, or compares keys as
/// signed, passes every test on small keys.
pub const KeyLayout = enum {
    /// k: the keys 0, 1, 2, ... (easy to read in a failure report).
    dense,
    /// 2^32 - key_space/2 + k: consecutive keys on both sides of 2^32.
    around_2_32,
    /// k * (2^64 / key_space): evenly over the whole range. Every key has
    /// the same low 32 bits (zero) and half of them have the top bit set.
    spread,
    /// 2^64 - 1 - key_space + k: the last keys below maxInt(u64). The key
    /// maxInt itself is left out because `range` is half-open: no [lo, hi)
    /// can contain it (base_search.zig).
    top,

    /// The key for index `k`. `k == key_space` is allowed: a range's
    /// exclusive upper bound is one past the largest index.
    pub fn key(self: KeyLayout, key_space: u64, k: u64) u64 {
        std.debug.assert(k <= key_space);
        return switch (self) {
            .dense => k,
            .around_2_32 => (1 << 32) - key_space / 2 + k,
            // key_space is a power of two (see `swarm`), so the stride is
            // exact. k == key_space would be 2^64: saturate, which names
            // the same set of keys because no key equals maxInt.
            .spread => k *| ((1 << 63) / key_space * 2),
            .top => std.math.maxInt(u64) - key_space + k,
        };
    }

    /// For the case description printed by `run`.
    pub fn describe(self: KeyLayout) []const u8 {
        return switch (self) {
            .dense => "from 0",
            .around_2_32 => "around 2^32",
            .spread => "spread over u64",
            .top => "below 2^64",
        };
    }
};

/// Everything that defines one fuzz run. `seed` is all a bug report needs
/// (together with the version of the code).
pub const Case = struct {
    seed: u64,
    /// Number of generated operations (the drain comes on top).
    count: u64,
    /// Number of distinct keys. Always a power of two.
    key_space: u64,
    /// Which `key_space` keys: see `KeyLayout`.
    key_layout: KeyLayout,
    weights: ops.Weights,
    /// A put gets injected allocation failures with probability
    /// 1 / fault_one_in; 0 = never, 1 = every put.
    fault_one_in: u64,
    /// Finish by deleting every remaining key in random order, so that the
    /// run ends on an empty tree (merges all the way up, root shrinks).
    drain: bool,
    /// Sub-seeds, so the three random decisions do not share a stream.
    stream_seed: u64,
    aux_seed: u64,
};

/// Swarm testing: instead of one "reasonable" configuration, every seed
/// draws its own. Some runs never delete (trees grow tall), some have four
/// possible keys (overwrite, delete-missing and the empty tree all the
/// time), some fail every allocation of every put, some use keys next to
/// 2^64. A fixed mix reaches the same few shapes over and over; the swarm
/// reaches the corners.
///
/// The draw order below is part of the contract: the Rust twin makes the
/// same draws in the same order.
pub fn swarm(seed: u64) Case {
    var prng = SplitMix64.init(seed);
    const key_spaces = [_]u64{ 4, 16, 64, 256 };
    const fault_rates = [_]u64{ 0, 1, 8, 2 };
    const key_space = key_spaces[@intCast(prng.below(4))];
    const count = @as(u64, 64) << @intCast(prng.below(4)); // 64, 128, 256 or 512
    const put: u32 = @intCast(1 + prng.below(8)); // never zero: something must be inserted
    const delete: u32 = if (prng.chance(1, 4)) 0 else @intCast(1 + prng.below(8));
    const get: u32 = if (prng.chance(1, 2)) 0 else @intCast(1 + prng.below(4));
    const range: u32 = if (prng.chance(1, 2)) 0 else @intCast(1 + prng.below(2));
    const fault_one_in = fault_rates[@intCast(prng.below(4))];
    const drain = prng.chance(1, 2);
    const stream_seed = prng.nextU64();
    const aux_seed = prng.nextU64();
    const key_layout: KeyLayout = @fromBackingInt(@intCast(prng.below(4)));
    return .{
        .seed = seed,
        .count = count,
        .key_space = key_space,
        .key_layout = key_layout,
        .weights = .{ .put = put, .delete = delete, .get = get, .range = range },
        .fault_one_in = fault_one_in,
        .drain = drain,
        .stream_seed = stream_seed,
        .aux_seed = aux_seed,
    };
}

/// The opposite of a swarm: the same mix for every seed (common/ default
/// weights 4:2:3:1, 64 small keys, no faults, no drain). Used to show what
/// a fixed configuration never reaches.
pub fn fixedMix(seed: u64) Case {
    return .{
        .seed = seed,
        .count = 256,
        .key_space = 64,
        .key_layout = .dense,
        .weights = .{},
        .fault_one_in = 0,
        .drain = false,
        .stream_seed = seed,
        .aux_seed = ~seed,
    };
}

/// The operation stream only produces ranges with lo < hi, both taken from
/// the keys of the case. Callers are not that polite, and the end of a scan
/// is exactly where an off-by-one or a wrapping subtraction hides, so 5
/// ranges in 16 get one of these shapes instead:
///
///   [hi, lo)        inverted: must be empty, like the oracle's
///   [lo, lo)        empty; with the smallest key of a dense case, [0, 0)
///   [0, hi)         from the smallest u64 ...
///   [lo, maxInt)    ... up to the largest bound there is ...
///   [0, maxInt)     ... or both: every key in the tree
fn reshapeRange(prng: *SplitMix64, lo: u64, hi: u64) ops.Op {
    const max = std.math.maxInt(u64);
    return switch (prng.below(16)) {
        0 => .{ .range = .{ .lo = hi, .hi = lo } },
        1 => .{ .range = .{ .lo = lo, .hi = lo } },
        2 => .{ .range = .{ .lo = 0, .hi = hi } },
        3 => .{ .range = .{ .lo = lo, .hi = max } },
        4 => .{ .range = .{ .lo = 0, .hi = max } },
        else => .{ .range = .{ .lo = lo, .hi = hi } },
    };
}

/// Produce the steps of a case. Caller frees the slice.
pub fn generate(gpa: Allocator, case: Case) Allocator.Error![]Step {
    var steps: std.ArrayList(Step) = .empty;
    errdefer steps.deinit(gpa);
    // Only here to know which keys are alive when the drain starts.
    var model: ops.Oracle = .{};
    defer model.deinit(gpa);
    var aux = SplitMix64.init(case.aux_seed);
    // A third stream, only for the shape of ranges: the faults and the drain
    // of a case do not depend on how many ranges it happens to contain.
    var shapes = SplitMix64.init(~case.aux_seed);
    var stream = ops.OpStream.init(.{
        .seed = case.stream_seed,
        .count = case.count,
        .key_space = case.key_space,
        .weights = case.weights,
    });
    while (stream.next()) |index_op| {
        // The stream speaks in key indices; the layout says which keys.
        const layout = case.key_layout;
        const ks = case.key_space;
        var step: Step = .{ .op = switch (index_op) {
            .put => |p| .{ .put = .{ .key = layout.key(ks, p.key), .value = p.value } },
            .delete => |d| .{ .delete = .{ .key = layout.key(ks, d.key) } },
            .get => |g| .{ .get = .{ .key = layout.key(ks, g.key) } },
            .range => |r| reshapeRange(&shapes, layout.key(ks, r.lo), layout.key(ks, r.hi)),
        } };
        switch (step.op) {
            .put => |p| {
                step.fault = case.fault_one_in > 0 and aux.chance(1, case.fault_one_in);
                _ = try model.put(gpa, p.key, p.value);
            },
            .delete => |d| _ = model.delete(d.key),
            .get, .range => {},
        }
        try steps.append(gpa, step);
    }
    if (case.drain) {
        const alive = model.range(0, std.math.maxInt(u64));
        const keys = try gpa.alloc(u64, alive.len);
        defer gpa.free(keys);
        for (keys, alive) |*key, entry| key.* = entry.key;
        aux.shuffle(keys);
        for (keys) |key| try steps.append(gpa, .{ .op = .{ .delete = .{ .key = key } } });
    }
    return steps.toOwnedSlice(gpa);
}

/// Which families of checks `replay` performs. Both are on in real use; the
/// tests switch one off to show what the other one cannot see.
pub const Checks = struct {
    /// `tree.validate()` after every step: structure and node accounting
    /// (including: a failed put leaves `pool.usage` as it was).
    validate: bool = true,
    /// Compare every answer with the oracle, and the full contents every
    /// `sweep_every` steps and after the last one.
    model: bool = true,
    sweep_every: usize = 16,
};

pub const Kind = union(enum) {
    /// `validate` returned this error after the step.
    invariant: validation.Error,
    /// The answer of the step itself differs from the oracle's.
    wrong_result,
    /// Key count or a full in-order scan differs from the oracle.
    wrong_contents,
    /// A put failed with OutOfMemory and left a trace: in the contents, in
    /// the structure or in the pool's counters (`pool.usage`).
    oom_changed_tree,
    /// Nodes still allocated after `deinit`.
    leak,
    /// Two replays that differ only in the bytes a freed node holds did not
    /// do the same thing: the tree read a node after giving it back. Found
    /// by `hunt`, not by a single `replay`, so `minimize` cannot shrink it.
    read_after_free,
};

pub const Failure = struct {
    /// Index of the step after which the check failed (0-based).
    step: usize,
    kind: Kind,
    diag: validation.Diagnostic = .{},

    /// Same class of failure? Used by the minimiser so that it does not
    /// wander off to a different bug while deleting steps.
    pub fn sameKind(self: Failure, other: Failure) bool {
        return std.meta.eql(self.kind, other.kind);
    }

    /// Printed with `{f}`: "invariant MissingChild at depth 1 (node starts with key 9)".
    pub fn format(self: Failure, w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self.kind) {
            .invariant => |err| {
                try w.print("invariant {t}", .{err});
                if (self.diag.first_key) |key| {
                    try w.print(" at depth {d} (node starts with key {d})", .{ self.diag.depth, key });
                }
            },
            .wrong_result => try w.writeAll("wrong result (answer differs from the oracle)"),
            .wrong_contents => try w.writeAll("wrong contents (full scan differs from the oracle)"),
            .oom_changed_tree => try w.writeAll("a failed put changed the tree or its node accounting"),
            .leak => try w.writeAll("leak (nodes still allocated after deinit)"),
            .read_after_free => try w.writeAll("use after free (the run depends on the bytes of a freed node)"),
        }
    }
};

/// What a batch of replays did, for reporting and for the coverage asserts.
pub const Totals = struct {
    cases: u64 = 0,
    steps: u64 = 0,
    injected_faults: u64 = 0,
    /// Most reserved nodes one failed put had to hand back.
    deepest_rollback: u64 = 0,
    max_height: usize = 0,
    max_keys: usize = 0,
    coverage: Coverage = .{},

    pub fn add(self: *Totals, other: *const Totals) void {
        self.cases += other.cases;
        self.steps += other.steps;
        self.injected_faults += other.injected_faults;
        self.deepest_rollback = @max(self.deepest_rollback, other.deepest_rollback);
        self.max_height = @max(self.max_height, other.max_height);
        self.max_keys = @max(self.max_keys, other.max_keys);
        self.coverage.add(&other.coverage);
    }
};

/// What freed nodes are filled with (see `replayWith`). Both bytes make a
/// node that `validate` rejects without following a wild pointer:
///   0x00  no keys, not a leaf, no children  -> EmptyRoot / NodeUnderfull / MissingChild
///   0x01  a leaf with 0x0101... keys        -> NodeOverfull
/// and they disagree about `leaf`, the one field a tree can read from a
/// dead node without anything else going wrong.
const first_poison: u8 = 0x00;
const second_poison: u8 = 0x01;

/// Run `steps` against a fresh `Tree` and a fresh oracle. Returns the first
/// failure, or null if every check passed. An error return means the test
/// itself ran out of memory, which is not a verdict about the tree.
///
/// Memory: the tree's nodes come from an arena, through the counting
/// FaultAllocator with its quarantine switched on. Two reasons:
///   * A tree that has just failed validation may have lost track of nodes;
///     no walk can find those, so on failure nothing is walked: the arena
///     releases everything in one go.
///   * A freed node must not stay readable. A bare arena hides every use
///     after free: `destroy` leaves the bytes alone and the memory stays
///     mapped, so the dead node answers exactly like the live one did. The
///     quarantine overwrites it and never hands it out again.
/// See README, "Which allocator where".
pub fn replay(comptime Tree: type, gpa: Allocator, steps: []const Step, checks: Checks, totals: ?*Totals) Allocator.Error!?Failure {
    const run = try replayWith(Tree, gpa, steps, checks, first_poison, totals != null);
    if (totals) |t| t.add(&run.totals);
    return run.failure;
}

const Run = struct { failure: ?Failure, totals: Totals };

/// `replay` with the byte for freed nodes as a parameter. `measure`: also
/// record height and key count after every step (one more walk per step).
fn replayWith(comptime Tree: type, gpa: Allocator, steps: []const Step, checks: Checks, poison: u8, measure: bool) Allocator.Error!Run {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var fault: FaultAllocator = .init(arena.allocator());
    fault.quarantine = poison;
    const tree_gpa = fault.allocator();
    var tree: Tree = .empty;
    var oracle: ops.Oracle = .{};
    defer oracle.deinit(gpa);

    var failure: ?Failure = null;
    var local: Totals = .{ .cases = 1 };
    for (steps, 0..) |step, i| {
        if (trace) traceStep(Tree.order, @tagName(Tree.bug), i, steps.len, step, poison);
        var diag: validation.Diagnostic = .{};
        const last = i + 1 == steps.len;
        const verdict = try applyAndCheck(Tree, &tree, tree_gpa, &fault, &oracle, gpa, step, checks, last or (i + 1) % checks.sweep_every == 0, &diag, &local);
        local.steps = i + 1;
        if (verdict) |kind| {
            failure = .{ .step = i, .kind = kind, .diag = diag };
            break;
        }
        if (measure) {
            const shape = tree.shape();
            local.max_height = @max(local.max_height, shape.height);
            local.max_keys = @max(local.max_keys, shape.keys);
        }
    }
    local.injected_faults = fault.injected;
    local.coverage = tree.coverage;

    if (failure == null and checks.validate) {
        // The tree is known to be sound, so it may free itself; afterwards
        // the counting allocator must be back at zero.
        tree.deinit(tree_gpa);
        if (fault.liveAllocations() != 0) failure = .{ .step = steps.len -| 1, .kind = .leak };
    }
    return .{ .failure = failure, .totals = local };
}

/// The second opinion on memory. `first` is a replay that passed with
/// `first_poison` in its freed nodes. Replay again with `second_poison`:
/// a tree that never looks at a freed node cannot tell the difference, so
/// both runs must pass and hit every coverage point equally often. If they
/// do not, the step is found by bisection: the shortest prefix of the steps
/// on which the two runs already disagree ends with the step that did it.
fn readAfterFree(comptime Tree: type, gpa: Allocator, steps: []const Step, checks: Checks, first: *const Run) Allocator.Error!?Failure {
    const second = try replayWith(Tree, gpa, steps, checks, second_poison, false);
    if (sameRun(first, &second)) return null;
    var same: usize = 0; // the runs agree on steps[0..same] ...
    var differ: usize = steps.len; // ... and disagree on steps[0..differ]
    while (differ - same > 1) {
        const mid = same + (differ - same) / 2;
        const a = try replayWith(Tree, gpa, steps[0..mid], checks, first_poison, false);
        const b = try replayWith(Tree, gpa, steps[0..mid], checks, second_poison, false);
        if (sameRun(&a, &b)) same = mid else differ = mid;
    }
    return .{ .step = differ -| 1, .kind = .read_after_free };
}

fn sameRun(a: *const Run, b: *const Run) bool {
    return std.meta.eql(a.failure, b.failure) and std.meta.eql(a.totals.coverage, b.totals.coverage);
}

fn applyAndCheck(
    comptime Tree: type,
    tree: *Tree,
    tree_gpa: Allocator,
    fault: *FaultAllocator,
    oracle: *ops.Oracle,
    gpa: Allocator,
    step: Step,
    checks: Checks,
    sweep: bool,
    diag: *validation.Diagnostic,
    local: *Totals,
) Allocator.Error!?Kind {
    var answer_ok = true;
    switch (step.op) {
        .put => |p| {
            // Fault injection: with `step.fault` the put is tried with its
            // node allocation 0 failing, then allocation 1, and so on. Each
            // failed attempt must return OutOfMemory and keep the promise
            // "nothing happened"; the first attempt whose armed fault lies
            // beyond the put's last allocation goes through.
            const usage_before = tree.pool.usage;
            var nth: u64 = 0;
            while (true) : (nth += 1) {
                const injected_before = fault.injected;
                if (step.fault) fault.failNth(nth);
                const attempt = tree.put(tree_gpa, p.key, p.value);
                fault.disarm();
                if (attempt) |got| {
                    answer_ok = got == try oracle.put(gpa, p.key, p.value);
                    break;
                } else |err| {
                    if (fault.injected == injected_before) return err; // the test itself is out of memory
                    // Allocation `nth` failed: `nth` nodes were already
                    // reserved and had to be handed back.
                    local.deepest_rollback = @max(local.deepest_rollback, nth);
                    // Structure first (a `get` on a malformed tree may
                    // abort), then the contents, then the pool's counters:
                    // "exactly as before the call" includes `pool.usage`.
                    if (checks.validate) tree.validate(diag) catch return .oom_changed_tree;
                    if (tree.len != oracle.len() or tree.get(p.key) != oracle.get(p.key)) return .oom_changed_tree;
                    if (checks.validate and !std.meta.eql(tree.pool.usage, usage_before)) return .oom_changed_tree;
                }
            }
        },
        .delete => |d| answer_ok = tree.delete(tree_gpa, d.key) == oracle.delete(d.key),
        .get => |g| answer_ok = tree.get(g.key) == oracle.get(g.key),
        .range => |r| {
            var cmp: Compare = .{ .expected = oracle.range(r.lo, r.hi) };
            tree.range(r.lo, r.hi, &cmp);
            answer_ok = cmp.matches();
        },
    }
    if (checks.model and !answer_ok) return .wrong_result;

    // Structure first: if the tree is malformed, walking it for the content
    // comparison below would not be safe.
    if (checks.validate) tree.validate(diag) catch |err| return .{ .invariant = err };

    if (checks.model) {
        if (tree.len != oracle.len()) return .wrong_contents;
        if (sweep) {
            var cmp: Compare = .{ .expected = oracle.range(0, std.math.maxInt(u64)) };
            tree.inOrder(&cmp);
            if (!cmp.matches()) return .wrong_contents;
        }
    }
    return null;
}

/// Visitor that checks a scan of the tree against a slice of the oracle,
/// entry by entry (keys AND values, in order, nothing missing or extra).
const Compare = struct {
    expected: []const ops.Entry,
    seen: usize = 0,
    ok: bool = true,

    pub fn visit(self: *Compare, key: u64, value: u64) void {
        if (self.seen >= self.expected.len) {
            self.ok = false;
        } else if (self.expected[self.seen].key != key or self.expected[self.seen].value != value) {
            self.ok = false;
        }
        self.seen += 1;
    }

    fn matches(self: *const Compare) bool {
        return self.ok and self.seen == self.expected.len;
    }
};

pub const Found = struct { case: Case, failure: Failure };

/// One swarm case per seed in [first_seed, first_seed + seeds). Returns the
/// first failing case, or null when all pass. With `checks.validate` (the
/// family that watches memory) a case that passes is replayed a second time
/// to look for a use after free: see `readAfterFree`.
pub fn hunt(comptime Tree: type, gpa: Allocator, first_seed: u64, seeds: u64, checks: Checks, totals: ?*Totals) Allocator.Error!?Found {
    for (first_seed..first_seed + seeds) |seed| {
        const case = swarm(seed);
        const steps = try generate(gpa, case);
        defer gpa.free(steps);
        trace_seed = seed;
        defer trace_seed = null;
        const run = try replayWith(Tree, gpa, steps, checks, first_poison, totals != null);
        if (totals) |t| t.add(&run.totals);
        var failure = run.failure;
        if (failure == null and checks.validate) failure = try readAfterFree(Tree, gpa, steps, checks, &run);
        if (failure) |f| return .{ .case = case, .failure = f };
    }
    return null;
}

pub const Census = struct {
    /// How many of the seeds exposed a failure.
    failing_seeds: u64 = 0,
    /// The failing case that got there in the fewest steps (ties: lowest seed).
    shortest: ?Found = null,
};

/// Like `hunt`, but runs EVERY seed and keeps the failure that needed the
/// fewest steps. A short failing run is the better starting point for the
/// minimiser, and the count says how easy the bug is to hit.
pub fn huntShortest(comptime Tree: type, gpa: Allocator, first_seed: u64, seeds: u64, checks: Checks) Allocator.Error!Census {
    var census: Census = .{};
    for (first_seed..first_seed + seeds) |seed| {
        const found = try hunt(Tree, gpa, seed, 1, checks, null) orelse continue;
        census.failing_seeds += 1;
        if (census.shortest == null or found.failure.step < census.shortest.?.failure.step) census.shortest = found;
    }
    return census;
}

/// One step per line: `put 7 = 70`, `delete 7`, `get 7`, `range [3, 9)`.
pub fn writeSteps(w: *std.Io.Writer, steps: []const Step, indent: []const u8) std.Io.Writer.Error!void {
    for (steps) |step| try w.print("{s}{f}\n", .{ indent, step });
}
