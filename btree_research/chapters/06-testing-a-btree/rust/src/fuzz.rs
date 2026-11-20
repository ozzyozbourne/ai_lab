//! The model-based fuzzer.
//!
//! ```text
//! swarm(seed)     -> Case             one seed decides the whole test: how
//!                                     many steps, how many distinct keys, the
//!                                     mix of operations, whether allocations fail
//! generate(case)  -> Vec<Step>        the operations, as plain data
//! replay(steps)   -> Option<Failure>  run them against the tree AND a
//!                                     trivially correct oracle; stop at the
//!                                     first difference
//! hunt(seeds)     -> Option<Found>    replay one swarm case per seed, stop at
//!                                     the first failure (hunt_shortest: try
//!                                     them all)
//! ```
//!
//! Operations are data, generated up front and replayed afterwards (never
//! "draw a random number, act on it immediately"). That is what makes a
//! failure reproducible from its seed, and what lets minimize.rs delete
//! steps from a failing sequence and run it again.
//!
//! `replay` takes a [`Subject`]: which order, which bug. The same harness
//! tests the correct tree at every order and each broken variant.
//!
//! A bug that corrupts the tree ends as a `Failure` with a step number. A bug
//! that trips an assert or an index check inside the tree PANICS before any
//! check runs, and the panic message does not know the seed. For that case
//! there is a trace mode: `cargo test --features trace` prints the seed and
//! every step to stderr BEFORE it runs, so the last lines before the panic
//! name the case (README, "When the tree crashes instead").

use crate::alloc_count;
use crate::base_btree::{BTree, Bug};
use crate::base_validate::{ValidateError, Violation};
use crate::coverage::Coverage;
use crate::ops::{Config, Entry, Op, OpStream, Oracle, Weights};
use crate::prng::SplitMix64;
use std::fmt;
use std::io::{self, Write};

/// Set by `cargo test --features trace` / `cargo run --features trace`.
pub const TRACE: bool = cfg!(feature = "trace");

/// One operation, plus an optional injected fault: "the `fault`-th node
/// allocation of this put fails" (0 = the first). Only puts allocate nodes.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Step {
    pub op: Op,
    pub fault: Option<u8>,
}

/// `put 7 = 70`, `delete 7`, `get 7`, `range [3, 9)`.
impl fmt::Display for Step {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self.op {
            Op::Put { key, value } => write!(f, "put {key} = {value}")?,
            Op::Delete { key } => write!(f, "delete {key}")?,
            Op::Get { key } => write!(f, "get {key}")?,
            Op::Range { lo, hi } => write!(f, "range [{lo}, {hi})")?,
        }
        if let Some(n) = self.fault {
            write!(f, " (node allocation {n} fails first)")?;
        }
        Ok(())
    }
}

/// Where in the 64-bit key space the keys of a case lie. The operation
/// stream draws a small index k in `0..key_space`; the layout turns it into
/// the key. All four are strictly increasing in k, so the SHAPE of the tree
/// is the same whichever is chosen; what changes is the numbers the tree has
/// to compare. A tree that truncates a key to 32 bits, or compares keys as
/// signed, passes every test on small keys.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum KeyLayout {
    /// k: the keys 0, 1, 2, ... (easy to read in a failure report).
    Dense,
    /// 2^32 - key_space/2 + k: consecutive keys on both sides of 2^32.
    Around2Pow32,
    /// k * (2^64 / key_space): evenly over the whole range. Every key has
    /// the same low 32 bits (zero) and half of them have the top bit set.
    Spread,
    /// 2^64 - 1 - key_space + k: the last keys below `u64::MAX`. The key
    /// `u64::MAX` itself is left out because `range` is half-open: no
    /// `lo..hi` can contain it (base_search.rs).
    Top,
}

impl KeyLayout {
    pub const ALL: [KeyLayout; 4] = [
        KeyLayout::Dense,
        KeyLayout::Around2Pow32,
        KeyLayout::Spread,
        KeyLayout::Top,
    ];

    /// The key for index `k`. `k == key_space` is allowed: a range's
    /// exclusive upper bound is one past the largest index.
    pub fn key(self, key_space: u64, k: u64) -> u64 {
        debug_assert!(k <= key_space);
        match self {
            KeyLayout::Dense => k,
            KeyLayout::Around2Pow32 => (1 << 32) - key_space / 2 + k,
            // key_space is a power of two (see `swarm`), so the stride is
            // exact. k == key_space would be 2^64: saturate, which names
            // the same set of keys because no key equals `u64::MAX`.
            KeyLayout::Spread => k.saturating_mul((1 << 63) / key_space * 2),
            KeyLayout::Top => u64::MAX - key_space + k,
        }
    }

    /// For the case description printed by `run`.
    pub fn describe(self) -> &'static str {
        match self {
            KeyLayout::Dense => "from 0",
            KeyLayout::Around2Pow32 => "around 2^32",
            KeyLayout::Spread => "spread over u64",
            KeyLayout::Top => "below 2^64",
        }
    }
}

/// Everything that defines one fuzz run. `seed` is all a bug report needs
/// (together with the version of the code).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Case {
    pub seed: u64,
    /// Number of generated operations (the drain comes on top).
    pub count: u64,
    /// Number of distinct keys. Always a power of two.
    pub key_space: u64,
    /// Which `key_space` keys: see [`KeyLayout`].
    pub key_layout: KeyLayout,
    pub weights: Weights,
    /// A put gets an injected allocation failure with probability
    /// 1 / fault_one_in; 0 = never.
    pub fault_one_in: u64,
    /// Finish by deleting every remaining key in random order, so that the
    /// run ends on an empty tree (merges all the way up, root shrinks).
    pub drain: bool,
    /// Sub-seeds, so the three random decisions do not share a stream.
    pub stream_seed: u64,
    pub aux_seed: u64,
}

/// Swarm testing: instead of one "reasonable" configuration, every seed
/// draws its own. Some runs never delete (trees grow tall), some have four
/// possible keys (overwrite, delete-missing and the empty tree all the
/// time), some fail a quarter of their allocations, some use keys next to
/// 2^64. A fixed mix reaches the same few shapes over and over; the swarm
/// reaches the corners.
///
/// The draw order below is part of the contract: the Zig twin makes the
/// same draws in the same order.
pub fn swarm(seed: u64) -> Case {
    const KEY_SPACES: [u64; 4] = [4, 16, 64, 256];
    const FAULT_RATES: [u64; 4] = [0, 0, 8, 2];
    let mut prng = SplitMix64::new(seed);
    let key_space = KEY_SPACES[prng.below(4) as usize];
    let count = 64 << prng.below(4); // 64, 128, 256 or 512
    let put = 1 + prng.below(8) as u32; // never zero: something must be inserted
    let delete = if prng.chance(1, 4) {
        0
    } else {
        1 + prng.below(8) as u32
    };
    let get = if prng.chance(1, 2) {
        0
    } else {
        1 + prng.below(4) as u32
    };
    let range = if prng.chance(1, 2) {
        0
    } else {
        1 + prng.below(2) as u32
    };
    let fault_one_in = FAULT_RATES[prng.below(4) as usize];
    let drain = prng.chance(1, 2);
    let stream_seed = prng.next_u64();
    let aux_seed = prng.next_u64();
    let key_layout = KeyLayout::ALL[prng.below(4) as usize];
    Case {
        seed,
        count,
        key_space,
        key_layout,
        weights: Weights {
            put,
            delete,
            get,
            range,
        },
        fault_one_in,
        drain,
        stream_seed,
        aux_seed,
    }
}

/// The opposite of a swarm: the same mix for every seed (common/ default
/// weights 4:2:3:1, 64 small keys, no faults, no drain). Used to show what
/// a fixed configuration never reaches.
pub fn fixed_mix(seed: u64) -> Case {
    Case {
        seed,
        count: 256,
        key_space: 64,
        key_layout: KeyLayout::Dense,
        weights: Weights::default(),
        fault_one_in: 0,
        drain: false,
        stream_seed: seed,
        aux_seed: !seed,
    }
}

/// Produce the steps of a case.
pub fn generate(case: Case) -> Vec<Step> {
    let mut steps = Vec::new();
    // Only here to know which keys are alive when the drain starts.
    let mut model = Oracle::new();
    let mut aux = SplitMix64::new(case.aux_seed);
    let stream = OpStream::new(Config {
        seed: case.stream_seed,
        count: case.count,
        key_space: case.key_space,
        weights: case.weights,
    });
    for index_op in stream {
        // The stream speaks in key indices; the layout says which keys.
        let at = |k| case.key_layout.key(case.key_space, k);
        let op = match index_op {
            Op::Put { key, value } => Op::Put {
                key: at(key),
                value,
            },
            Op::Delete { key } => Op::Delete { key: at(key) },
            Op::Get { key } => Op::Get { key: at(key) },
            Op::Range { lo, hi } => Op::Range {
                lo: at(lo),
                hi: at(hi),
            },
        };
        let mut step = Step { op, fault: None };
        match op {
            Op::Put { key, value } => {
                if case.fault_one_in > 0 && aux.chance(1, case.fault_one_in) {
                    step.fault = Some(aux.below(3) as u8);
                }
                model.put(key, value);
            }
            Op::Delete { key } => {
                model.delete(key);
            }
            Op::Get { .. } | Op::Range { .. } => {}
        }
        steps.push(step);
    }
    if case.drain {
        let mut keys: Vec<u64> = model.range(0, u64::MAX).iter().map(|e| e.key).collect();
        aux.shuffle(&mut keys);
        steps.extend(keys.into_iter().map(|key| Step {
            op: Op::Delete { key },
            fault: None,
        }));
    }
    steps
}

/// Which tree to build: the order and the (possibly absent) bug.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Subject {
    pub order: usize,
    pub bug: Bug,
}

impl Subject {
    pub fn correct(order: usize) -> Self {
        Self {
            order,
            bug: Bug::None,
        }
    }
}

/// Which families of checks `replay` performs. Both are on in real use; the
/// tests switch one off to show what the other one cannot see.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Checks {
    /// `tree.validate()` after every step: structure and node accounting
    /// (including: a failed put leaves `pool.usage` as it was).
    pub validate: bool,
    /// Compare every answer with the oracle, and the full contents every
    /// `sweep_every` steps and after the last one.
    pub model: bool,
    pub sweep_every: usize,
}

impl Default for Checks {
    fn default() -> Self {
        Self {
            validate: true,
            model: true,
            sweep_every: 16,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Kind {
    /// `validate` returned this error after the step.
    Invariant(ValidateError),
    /// The answer of the step itself differs from the oracle's.
    WrongResult,
    /// Key count or a full in-order scan differs from the oracle.
    WrongContents,
    /// A put failed with `OutOfNodes` and left a trace: in the contents, in
    /// the structure, in the slab's counters (`pool.usage`) or as a slab
    /// slot that is still occupied (a reserved node that was not handed back).
    OomChangedTree,
    /// Heap allocations still live after the tree was dropped. This check
    /// can only see memory that escaped the tree's ownership altogether
    /// (`mem::forget`, a reference cycle). It can NOT see a lost node: every
    /// slot lives in the slab's `Vec`, which is dropped whole. Lost nodes
    /// are found by `BTree::validate`, which counts occupied slots.
    Leak,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Failure {
    /// Index of the step after which the check failed (0-based).
    pub step: usize,
    pub kind: Kind,
    /// For `Kind::Invariant`: where the walk stopped.
    pub depth: usize,
    pub first_key: Option<u64>,
}

impl Failure {
    fn new(step: usize, verdict: Verdict) -> Self {
        Self {
            step,
            kind: verdict.kind,
            depth: verdict.depth,
            first_key: verdict.first_key,
        }
    }

    /// Same class of failure? Used by the minimiser so that it does not
    /// wander off to a different bug while deleting steps.
    pub fn same_kind(&self, other: &Failure) -> bool {
        self.kind == other.kind
    }
}

/// "invariant MissingChild at depth 1 (node starts with key 9)".
impl fmt::Display for Failure {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self.kind {
            Kind::Invariant(error) => {
                write!(f, "invariant {error:?}")?;
                if let Some(key) = self.first_key {
                    write!(f, " at depth {} (node starts with key {key})", self.depth)?;
                }
                Ok(())
            }
            Kind::WrongResult => f.write_str("wrong result (answer differs from the oracle)"),
            Kind::WrongContents => {
                f.write_str("wrong contents (full scan differs from the oracle)")
            }
            Kind::OomChangedTree => {
                f.write_str("a failed put changed the tree or its node accounting")
            }
            Kind::Leak => f.write_str("leak (nodes still allocated after deinit)"),
        }
    }
}

/// A failed check, before it is tied to a step number.
struct Verdict {
    kind: Kind,
    depth: usize,
    first_key: Option<u64>,
}

impl From<Kind> for Verdict {
    fn from(kind: Kind) -> Self {
        Self {
            kind,
            depth: 0,
            first_key: None,
        }
    }
}

impl From<Violation> for Verdict {
    fn from(v: Violation) -> Self {
        Self {
            kind: Kind::Invariant(v.error),
            depth: v.depth,
            first_key: v.first_key,
        }
    }
}

/// What a batch of replays did, for reporting and for the coverage asserts.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct Totals {
    pub cases: u64,
    pub steps: u64,
    pub injected_faults: u64,
    pub max_height: usize,
    pub max_keys: usize,
    pub coverage: Coverage,
}

/// Run `steps` against a fresh tree and a fresh oracle. Returns the first
/// failure, or `None` if every check passed.
///
/// Memory: the Zig twin puts the tree's nodes in an arena, because a tree
/// that failed validation cannot be trusted to free itself. Here dropping
/// the slab frees every node, reachable or not, so nothing special is
/// needed. The counting global allocator then confirms that the whole run
/// gave back everything it took (see `Kind::Leak` for what that can show).
pub fn replay(
    subject: Subject,
    steps: &[Step],
    checks: Checks,
    totals: Option<&mut Totals>,
) -> Option<Failure> {
    let live_before = alloc_count::stats().live();
    let mut local = Totals {
        cases: 1,
        ..Totals::default()
    };
    let mut failure = run(subject, steps, checks, totals.is_some(), &mut local);
    // `run` has returned: tree, slab and oracle are dropped.
    if failure.is_none() && alloc_count::stats().live() != live_before {
        failure = Some(Failure::new(
            steps.len().saturating_sub(1),
            Kind::Leak.into(),
        ));
    }
    if let Some(t) = totals {
        t.cases += local.cases;
        t.steps += local.steps;
        t.injected_faults += local.injected_faults;
        t.max_height = t.max_height.max(local.max_height);
        t.max_keys = t.max_keys.max(local.max_keys);
        t.coverage.add(&local.coverage);
    }
    failure
}

fn run(
    subject: Subject,
    steps: &[Step],
    checks: Checks,
    measure: bool,
    local: &mut Totals,
) -> Option<Failure> {
    let mut tree = BTree::with_bug(subject.order, subject.bug);
    let mut oracle = Oracle::new();
    let mut failure = None;
    if TRACE {
        eprintln!(
            "trace: replay of {} steps, M={}, bug {}",
            steps.len(),
            subject.order,
            subject.bug.name()
        );
    }
    for (i, &step) in steps.iter().enumerate() {
        // Before the step, not after: if the tree panics inside it, this
        // line is the last thing on stderr.
        if TRACE {
            eprintln!("trace:   step {}: {step}", i + 1);
        }
        let sweep = i + 1 == steps.len() || (i + 1) % checks.sweep_every == 0;
        let verdict = apply_and_check(&mut tree, &mut oracle, step, checks, sweep, local);
        local.steps = i as u64 + 1;
        if let Err(verdict) = verdict {
            failure = Some(Failure::new(i, verdict));
            break;
        }
        if measure {
            let shape = tree.shape();
            local.max_height = local.max_height.max(shape.height);
            local.max_keys = local.max_keys.max(shape.keys);
        }
    }
    local.coverage = tree.coverage;
    failure
}

fn apply_and_check(
    tree: &mut BTree,
    oracle: &mut Oracle,
    step: Step,
    checks: Checks,
    sweep: bool,
    local: &mut Totals,
) -> Result<(), Verdict> {
    let answer_ok = match step.op {
        Op::Put { key, value } => {
            // Fault injection: let the n-th node allocation of this put
            // fail. If the put needed that many nodes it returns
            // `OutOfNodes`, and the promise is "nothing happened".
            let usage_before = tree.pool.usage;
            tree.pool.fail_after = step.fault.map(u64::from);
            let first_try = tree.put(key, value);
            tree.pool.fail_after = None;
            let got = match first_try {
                Ok(got) => got,
                Err(_) => {
                    local.injected_faults += 1;
                    // Structure first (a `get` on a malformed tree may
                    // panic), then the contents, then the slab's counters:
                    // "exactly as before the call" includes `pool.usage`.
                    // `validate` also counts the occupied slab slots, so a
                    // reserved node that was not handed back is caught here.
                    if checks.validate && tree.validate().is_err() {
                        return Err(Kind::OomChangedTree.into());
                    }
                    if tree.len != oracle.len() || tree.get(key) != oracle.get(key) {
                        return Err(Kind::OomChangedTree.into());
                    }
                    if checks.validate && tree.pool.usage != usage_before {
                        return Err(Kind::OomChangedTree.into());
                    }
                    // The operation still has to happen: try again, unharmed.
                    tree.put(key, value).expect("no fault armed, no budget")
                }
            };
            got == oracle.put(key, value)
        }
        Op::Delete { key } => tree.delete(key) == oracle.delete(key),
        Op::Get { key } => tree.get(key) == oracle.get(key),
        Op::Range { lo, hi } => {
            let mut cmp = Compare::new(oracle.range(lo, hi));
            tree.range(lo, hi, |key, value| cmp.visit(key, value));
            cmp.matches()
        }
    };
    if checks.model && !answer_ok {
        return Err(Kind::WrongResult.into());
    }

    // Structure first: the content comparison below walks the tree, which
    // only makes sense on a well-formed one.
    if checks.validate {
        tree.validate()?;
    }

    if checks.model {
        if tree.len != oracle.len() {
            return Err(Kind::WrongContents.into());
        }
        if sweep {
            let mut cmp = Compare::new(oracle.range(0, u64::MAX));
            tree.in_order(|key, value| cmp.visit(key, value));
            if !cmp.matches() {
                return Err(Kind::WrongContents.into());
            }
        }
    }
    Ok(())
}

/// Checks a scan of the tree against a slice of the oracle, entry by entry
/// (keys AND values, in order, nothing missing or extra).
struct Compare<'a> {
    expected: &'a [Entry],
    seen: usize,
    ok: bool,
}

impl<'a> Compare<'a> {
    fn new(expected: &'a [Entry]) -> Self {
        Self {
            expected,
            seen: 0,
            ok: true,
        }
    }

    fn visit(&mut self, key: u64, value: u64) {
        if self.expected.get(self.seen) != Some(&Entry { key, value }) {
            self.ok = false;
        }
        self.seen += 1;
    }

    fn matches(&self) -> bool {
        self.ok && self.seen == self.expected.len()
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Found {
    pub case: Case,
    pub failure: Failure,
}

/// One swarm case per seed in `first_seed..first_seed + seeds`. Returns the
/// first failing case, or `None` when all pass.
pub fn hunt(
    subject: Subject,
    first_seed: u64,
    seeds: u64,
    checks: Checks,
    mut totals: Option<&mut Totals>,
) -> Option<Found> {
    for seed in first_seed..first_seed + seeds {
        let case = swarm(seed);
        let steps = generate(case);
        if TRACE {
            eprintln!("trace: seed {seed}");
        }
        if let Some(failure) = replay(subject, &steps, checks, totals.as_deref_mut()) {
            return Some(Found { case, failure });
        }
    }
    None
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct Census {
    /// How many of the seeds exposed a failure.
    pub failing_seeds: u64,
    /// The failing case that got there in the fewest steps (ties: lowest seed).
    pub shortest: Option<Found>,
}

/// Like `hunt`, but runs EVERY seed and keeps the failure that needed the
/// fewest steps. A short failing run is the better starting point for the
/// minimiser, and the count says how easy the bug is to hit.
pub fn hunt_shortest(subject: Subject, first_seed: u64, seeds: u64, checks: Checks) -> Census {
    let mut census = Census::default();
    for seed in first_seed..first_seed + seeds {
        let Some(found) = hunt(subject, seed, 1, checks, None) else {
            continue;
        };
        census.failing_seeds += 1;
        if census
            .shortest
            .is_none_or(|best| found.failure.step < best.failure.step)
        {
            census.shortest = Some(found);
        }
    }
    census
}

/// One step per line: `put 7 = 70`, `delete 7`, `get 7`, `range [3, 9)`.
pub fn write_steps(w: &mut dyn Write, steps: &[Step], indent: &str) -> io::Result<()> {
    for step in steps {
        writeln!(w, "{indent}{step}")?;
    }
    Ok(())
}
