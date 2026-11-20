//! Minimisation: turn "seed 7 fails at step 131" into a handful of steps a
//! person can follow by hand.
//!
//! The method is delta debugging by chunk removal:
//!
//! 1. cut everything after the failing step (it never ran);
//! 2. try to delete a chunk of steps; if the shorter sequence STILL FAILS IN
//!    THE SAME WAY, keep it, otherwise put the chunk back;
//! 3. start with chunks of half the sequence and halve the chunk size after
//!    each pass, down to single steps. This is the fast part: it throws away
//!    most of a long run in few replays;
//! 4. finish exhaustively: try to remove EVERY contiguous block of steps
//!    (every start, every length, longest first), and start over whenever
//!    one goes. Chunk sizes that only shrink would miss a pair of steps that
//!    can only go together (a put and the delete that undoes it), because by
//!    the time single steps are stable no larger chunk is tried again.
//!
//! The guarantee, exactly: in the result no contiguous block of steps, of
//! any length, can be removed without losing the failure. In particular no
//! single step can (1-minimal). It is NOT the shortest failing sequence:
//! removing two steps that are not next to each other is never tried (that
//! search is exponential), and a shorter reproducer may not be a
//! subsequence of this run at all.
//!
//! Then three cosmetic passes make the survivor readable: forget injected
//! faults, rename the keys 1, 2, 3, ... (keeping their order), and replace
//! the random 64-bit values with 1, 2, 3, ... Each pass is kept only if the
//! sequence still fails in the same way.
//!
//! "The same way" matters. Deleting steps from a sequence that breaks
//! invariant A can produce a sequence that breaks B for an unrelated reason;
//! accepting it would silently swap the bug being chased (`Failure::same_kind`).

use crate::fuzz::{self, Checks, Failure, Step, Subject};
use crate::ops::Op;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Minimized {
    /// The reproducer; its last step is the failing one.
    pub steps: Vec<Step>,
    pub failure: Failure,
    /// How many times the tree was rebuilt and replayed to get here.
    pub replays: usize,
}

pub fn minimize(subject: Subject, original: &[Step], target: Failure, checks: Checks) -> Minimized {
    let mut m = Minimizer {
        subject,
        target,
        checks,
        current: original[..=target.step].to_vec(),
        failure: target,
        replays: 0,
    };

    // Fast reduction: aligned chunks, halving.
    let mut chunk = (m.current.len() / 2).max(1);
    loop {
        let mut i = 0;
        while i < m.current.len() {
            // On success do not advance: the next chunk slid to position i.
            if !m.try_without(i, i + chunk) {
                i += chunk;
            }
        }
        if chunk == 1 {
            break;
        }
        chunk /= 2;
    }
    // Exhaustive finish: every contiguous block, longest first, until a
    // whole round removes nothing. Each success shortens the sequence, so
    // this ends; a round costs about n^2 / 2 replays for n steps, which is
    // why the fast reduction comes first.
    'restart: loop {
        let n = m.current.len();
        // Removing all n steps leaves nothing to fail: start at n - 1.
        for len in (1..n).rev() {
            for start in 0..=n - len {
                if m.try_without(start, start + len) {
                    continue 'restart;
                }
            }
        }
        break;
    }

    m.without_faults();
    m.renumber_keys();
    m.small_values();
    Minimized {
        steps: m.current,
        failure: m.failure,
        replays: m.replays,
    }
}

struct Minimizer {
    subject: Subject,
    target: Failure,
    checks: Checks,
    /// The shortest failing sequence so far, and how it fails.
    current: Vec<Step>,
    failure: Failure,
    replays: usize,
}

impl Minimizer {
    /// Try the current sequence without steps `start..end`.
    fn try_without(&mut self, start: usize, end: usize) -> bool {
        let end = end.min(self.current.len());
        let mut candidate = self.current[..start].to_vec();
        candidate.extend_from_slice(&self.current[end..]);
        self.accept_if_still_failing(candidate)
    }

    /// Replay `candidate`. If it fails like the target, it becomes `current`
    /// (cut after its failing step) and the result is true.
    fn accept_if_still_failing(&mut self, mut candidate: Vec<Step>) -> bool {
        self.replays += 1;
        match fuzz::replay(self.subject, &candidate, self.checks, None) {
            Some(failure) if failure.same_kind(&self.target) => {
                candidate.truncate(failure.step + 1);
                self.current = candidate;
                self.failure = failure;
                true
            }
            _ => false,
        }
    }

    fn without_faults(&mut self) {
        let mut candidate = self.current.clone();
        for step in &mut candidate {
            step.fault = None;
        }
        self.accept_if_still_failing(candidate);
    }

    /// A B-tree only ever compares keys, so any order-preserving renaming is
    /// the same test. Rank 1 goes to the smallest number mentioned.
    fn renumber_keys(&mut self) {
        let mut seen = Vec::new();
        for step in &self.current {
            match step.op {
                Op::Put { key, .. } | Op::Delete { key } | Op::Get { key } => seen.push(key),
                Op::Range { lo, hi } => seen.extend([lo, hi]),
            }
        }
        seen.sort_unstable();
        let mut candidate = self.current.clone();
        for step in &mut candidate {
            match &mut step.op {
                Op::Put { key, .. } | Op::Delete { key } | Op::Get { key } => {
                    *key = rank(&seen, *key);
                }
                Op::Range { lo, hi } => {
                    *lo = rank(&seen, *lo);
                    *hi = rank(&seen, *hi);
                }
            }
        }
        self.accept_if_still_failing(candidate);
    }

    /// The n-th put writes the value n.
    fn small_values(&mut self) {
        let mut candidate = self.current.clone();
        let mut n = 0;
        for step in &mut candidate {
            if let Op::Put { value, .. } = &mut step.op {
                n += 1;
                *value = n;
            }
        }
        self.accept_if_still_failing(candidate);
    }
}

/// 1 + the number of DISTINCT values in `sorted` that are smaller than `x`.
fn rank(sorted: &[u64], x: u64) -> u64 {
    let mut distinct = 0;
    for (i, &value) in sorted.iter().enumerate() {
        if value >= x {
            break;
        }
        if i == 0 || sorted[i - 1] != value {
            distinct += 1;
        }
    }
    distinct + 1
}

#[cfg(test)]
mod tests {
    use super::rank;

    #[test]
    fn rank_renumbers_in_order_and_ignores_repeats() {
        let sorted = [5, 5, 9, 40, 40, 41];
        assert_eq!(rank(&sorted, 5), 1);
        assert_eq!(rank(&sorted, 9), 2);
        assert_eq!(rank(&sorted, 40), 3);
        assert_eq!(rank(&sorted, 41), 4);
    }
}
