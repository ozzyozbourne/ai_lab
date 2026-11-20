//! The model-based fuzzer.
//!
//!   swarm(seed)      -> Case     one seed decides the whole test: how many
//!                                steps, how many distinct keys, the mix of
//!                                operations, whether allocations fail
//!   generate(case)   -> []Step   the operations, as plain data
//!   replay(steps)    -> ?Failure run them against the tree AND a trivially
//!                                correct oracle; stop at the first difference
//!   hunt(seeds)      -> ?Found   replay one swarm case per seed, stop at the
//!                                first failure (huntShortest: try them all)
//!
//! Operations are data, generated up front and replayed afterwards (never
//! "draw a random number, act on it immediately"). That is what makes a
//! failure reproducible from its seed, and what lets minimize.zig delete
//! steps from a failing sequence and run it again.
//!
//! `replay` is generic over the tree type, so the same harness tests the
//! correct tree at every order and each broken variant (base_btree.zig, `Bug`).
const std = @import("std");
const Allocator = std.mem.Allocator;
const ops = @import("ops.zig");
const SplitMix64 = @import("prng.zig").SplitMix64;
const validation = @import("base_validate.zig");
const Coverage = @import("coverage.zig").Coverage;
const FaultAllocator = @import("fault_alloc.zig").FaultAllocator;

/// One operation, plus an optional injected fault: "the `fault`-th node
/// allocation of this put fails" (0 = the first). Only puts allocate.
pub const Step = struct {
    op: ops.Op,
    fault: ?u8 = null,
};

/// Everything that defines one fuzz run. `seed` is all a bug report needs
/// (together with the version of the code).
pub const Case = struct {
    seed: u64,
    /// Number of generated operations (the drain comes on top).
    count: u64,
    /// Keys are drawn from [0, key_space).
    key_space: u64,
    weights: ops.Weights,
    /// A put gets an injected allocation failure with probability
    /// 1 / fault_one_in; 0 = never.
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
/// time), some fail a quarter of their allocations. A fixed mix reaches the
/// same few shapes over and over; the swarm reaches the corners.
///
/// The draw order below is part of the contract: the Rust twin makes the
/// same draws in the same order.
pub fn swarm(seed: u64) Case {
    var prng = SplitMix64.init(seed);
    const key_spaces = [_]u64{ 4, 16, 64, 256 };
    const fault_rates = [_]u64{ 0, 0, 8, 2 };
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
    return .{
        .seed = seed,
        .count = count,
        .key_space = key_space,
        .weights = .{ .put = put, .delete = delete, .get = get, .range = range },
        .fault_one_in = fault_one_in,
        .drain = drain,
        .stream_seed = stream_seed,
        .aux_seed = aux_seed,
    };
}

/// The opposite of a swarm: the same mix for every seed (common/ default
/// weights 4:2:3:1, 64 keys, no faults, no drain). Used to show what a
/// fixed configuration never reaches.
pub fn fixedMix(seed: u64) Case {
    return .{
        .seed = seed,
        .count = 256,
        .key_space = 64,
        .weights = .{},
        .fault_one_in = 0,
        .drain = false,
        .stream_seed = seed,
        .aux_seed = ~seed,
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
    var stream = ops.OpStream.init(.{
        .seed = case.stream_seed,
        .count = case.count,
        .key_space = case.key_space,
        .weights = case.weights,
    });
    while (stream.next()) |op| {
        var step: Step = .{ .op = op };
        switch (op) {
            .put => |p| {
                if (case.fault_one_in > 0 and aux.chance(1, case.fault_one_in)) {
                    step.fault = @intCast(aux.below(3));
                }
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
    /// `tree.validate()` after every step: structure and node accounting.
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
    /// A put failed with OutOfMemory and left a trace in the tree.
    oom_changed_tree,
    /// Nodes still allocated after `deinit`.
    leak,
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
            .oom_changed_tree => try w.writeAll("a failed put changed the tree"),
            .leak => try w.writeAll("leak (nodes still allocated after deinit)"),
        }
    }
};

/// What a batch of replays did, for reporting and for the coverage asserts.
pub const Totals = struct {
    cases: u64 = 0,
    steps: u64 = 0,
    injected_faults: u64 = 0,
    max_height: usize = 0,
    max_keys: usize = 0,
    coverage: Coverage = .{},
};

/// Run `steps` against a fresh `Tree` and a fresh oracle. Returns the first
/// failure, or null if every check passed. An error return means the test
/// itself ran out of memory, which is not a verdict about the tree.
///
/// Memory: the tree's nodes come from an arena (wrapped in the counting
/// FaultAllocator). A tree that has just failed validation may have lost
/// track of nodes; no walk can find those, so on failure nothing is walked:
/// the arena releases everything in one go. See README, "Allocator notes".
pub fn replay(comptime Tree: type, gpa: Allocator, steps: []const Step, checks: Checks, totals: ?*Totals) Allocator.Error!?Failure {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var fault: FaultAllocator = .init(arena.allocator());
    const tree_gpa = fault.allocator();
    var tree: Tree = .empty;
    var oracle: ops.Oracle = .{};
    defer oracle.deinit(gpa);

    var failure: ?Failure = null;
    var done: usize = 0;
    var local: Totals = .{ .cases = 1 };
    for (steps, 0..) |step, i| {
        var diag: validation.Diagnostic = .{};
        const last = i + 1 == steps.len;
        const verdict = try applyAndCheck(Tree, &tree, tree_gpa, &fault, &oracle, gpa, step, checks, last or (i + 1) % checks.sweep_every == 0, &diag);
        done = i + 1;
        if (verdict) |kind| {
            failure = .{ .step = i, .kind = kind, .diag = diag };
            break;
        }
        if (totals != null) {
            const shape = tree.shape();
            local.max_height = @max(local.max_height, shape.height);
            local.max_keys = @max(local.max_keys, shape.keys);
        }
    }
    local.steps = done;
    local.injected_faults = fault.injected;
    local.coverage = tree.coverage;

    if (failure == null and checks.validate) {
        // The tree is known to be sound, so it may free itself; afterwards
        // the counting allocator must be back at zero.
        tree.deinit(tree_gpa);
        if (fault.liveAllocations() != 0) failure = .{ .step = steps.len -| 1, .kind = .leak };
    }
    if (totals) |t| {
        t.cases += local.cases;
        t.steps += local.steps;
        t.injected_faults += local.injected_faults;
        t.max_height = @max(t.max_height, local.max_height);
        t.max_keys = @max(t.max_keys, local.max_keys);
        t.coverage.add(&local.coverage);
    }
    return failure;
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
) Allocator.Error!?Kind {
    var answer_ok = true;
    switch (step.op) {
        .put => |p| {
            if (step.fault) |n| {
                // Fault injection: let the n-th node allocation of this put
                // fail. If the put needed that many nodes it returns
                // OutOfMemory, and the promise is "nothing happened".
                const injected_before = fault.injected;
                fault.failNth(n);
                const first_try = tree.put(tree_gpa, p.key, p.value);
                fault.disarm();
                if (first_try) |got| {
                    answer_ok = got == try oracle.put(gpa, p.key, p.value);
                } else |err| {
                    if (fault.injected == injected_before) return err; // the test itself is out of memory
                    if (tree.len != oracle.len() or tree.get(p.key) != oracle.get(p.key)) return .oom_changed_tree;
                    if (checks.validate) tree.validate(diag) catch return .oom_changed_tree;
                    // The operation still has to happen: try again, unharmed.
                    answer_ok = try tree.put(tree_gpa, p.key, p.value) == try oracle.put(gpa, p.key, p.value);
                }
            } else {
                answer_ok = try tree.put(tree_gpa, p.key, p.value) == try oracle.put(gpa, p.key, p.value);
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
/// first failing case, or null when all pass.
pub fn hunt(comptime Tree: type, gpa: Allocator, first_seed: u64, seeds: u64, checks: Checks, totals: ?*Totals) Allocator.Error!?Found {
    for (first_seed..first_seed + seeds) |seed| {
        const case = swarm(seed);
        const steps = try generate(gpa, case);
        defer gpa.free(steps);
        if (try replay(Tree, gpa, steps, checks, totals)) |failure| return .{ .case = case, .failure = failure };
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
    for (steps) |step| {
        try w.writeAll(indent);
        switch (step.op) {
            .put => |p| try w.print("put {d} = {d}", .{ p.key, p.value }),
            .delete => |d| try w.print("delete {d}", .{d.key}),
            .get => |g| try w.print("get {d}", .{g.key}),
            .range => |r| try w.print("range [{d}, {d})", .{ r.lo, r.hi }),
        }
        if (step.fault) |n| try w.print(" (node allocation {d} fails first)", .{n});
        try w.writeByte('\n');
    }
}
