//! Instrumented twins of the functions in search.rs.
//!
//! The functions in search.rs are kept free of bookkeeping so that they read
//! like the textbook. To SHOW what they do (the step table in the program
//! output and in the visualization) and to COUNT comparisons, this file
//! repeats the same loops with a recorder attached. The tests at the bottom
//! prove that every twin returns exactly what the plain function returns.

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Mode {
    Lower,
    Upper,
}

/// One iteration of the binary search loop.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Step {
    pub lo: usize,
    pub hi: usize,
    pub mid: usize,
    /// keys[mid], the only element this iteration looks at.
    pub probe: u64,
    /// true: the probe goes to the left group, `lo = mid + 1`.
    /// false: the probe goes to the right group, `hi = mid`.
    pub go_right: bool,
}

/// More steps than any slice can need: one per bit of an index, plus one.
pub const MAX_STEPS: usize = usize::BITS as usize + 1;

pub struct Trace<'a> {
    pub steps: &'a [Step],
    pub index: usize,
}

/// `lower_bound` / `upper_bound` with every iteration written into `buffer`
/// (caller memory again: tracing does not allocate either).
pub fn trace_bound<'a>(keys: &[u64], key: u64, mode: Mode, buffer: &'a mut [Step; MAX_STEPS]) -> Trace<'a> {
    let mut count = 0;
    let mut lo = 0;
    let mut hi = keys.len();
    while lo < hi {
        let mid = lo + (hi - lo) / 2;
        let go_right = match mode {
            Mode::Lower => keys[mid] < key,
            Mode::Upper => keys[mid] <= key,
        };
        buffer[count] = Step { lo, hi, mid, probe: keys[mid], go_right };
        count += 1;
        if go_right {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    Trace { steps: &buffer[..count], index: lo }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Counted {
    pub index: usize,
    /// Number of key comparisons (`keys[i] < key` evaluations).
    pub comparisons: u64,
}

pub fn lower_bound_counted(keys: &[u64], key: u64) -> Counted {
    let mut buffer = [Step::default(); MAX_STEPS];
    let t = trace_bound(keys, key, Mode::Lower, &mut buffer);
    Counted { index: t.index, comparisons: t.steps.len() as u64 }
}

/// `search::gallop_lower_bound` with a comparison counter. Same structure,
/// line for line; see the comments there.
pub fn gallop_lower_bound_counted(keys: &[u64], from: usize, key: u64) -> Counted {
    assert!(from <= keys.len());
    if from == keys.len() {
        return Counted { index: from, comparisons: 0 };
    }
    let mut comparisons = 1;
    if keys[from] >= key {
        return Counted { index: from, comparisons };
    }

    let mut below = from;
    let mut step = 1;
    let mut hi = keys.len();
    while step < keys.len() - below {
        let probe = below + step;
        comparisons += 1;
        if keys[probe] >= key {
            hi = probe;
            break;
        }
        below = probe;
        step *= 2;
    }
    let first = below + 1;
    let inner = lower_bound_counted(&keys[first..hi], key);
    Counted { index: first + inner.index, comparisons: comparisons + inner.comparisons }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use crate::prng::SplitMix64;
    use crate::search;

    #[test]
    fn trace_of_the_worked_example_lower_bound_13_on_the_canonical_keys() {
        let keys = [1, 3, 5, 6, 7, 10, 12, 15, 17, 20, 25, 30];
        let mut buffer = [Step::default(); MAX_STEPS];
        let t = trace_bound(&keys, 13, Mode::Lower, &mut buffer);
        assert_eq!(t.index, 7);
        assert_eq!(
            t.steps,
            [
                Step { lo: 0, hi: 12, mid: 6, probe: 12, go_right: true },
                Step { lo: 7, hi: 12, mid: 9, probe: 20, go_right: false },
                Step { lo: 7, hi: 9, mid: 8, probe: 17, go_right: false },
                Step { lo: 7, hi: 8, mid: 7, probe: 15, go_right: false },
            ]
        );
    }

    #[test]
    fn seeded_the_twins_return_what_the_plain_functions_return_within_the_bound() {
        let mut scratch = [0u64; 200];
        let mut rng = SplitMix64::new(0x0202);
        let mut buffer = [Step::default(); MAX_STEPS];
        for round in 0..200 {
            let n = rng.below(200) as usize;
            let gap = if round % 2 == 0 { 3 } else { 50 };
            let (keys, _rest) = search::make_sorted(&mut scratch, &mut rng, n, gap).unwrap();
            let keys = &*keys;
            let top = keys.last().map_or(10, |&last| last + 2);
            for _ in 0..40 {
                let key = rng.below(top);
                let lower = trace_bound(keys, key, Mode::Lower, &mut buffer);
                assert_eq!(lower.index, search::lower_bound(keys, key));
                assert!(lower.steps.len() as u64 <= search::max_comparisons(n));
                let upper = trace_bound(keys, key, Mode::Upper, &mut buffer);
                assert_eq!(upper.index, search::upper_bound(keys, key));
                assert!(upper.steps.len() as u64 <= search::max_comparisons(n));

                let from = rng.below(n as u64 + 1) as usize;
                let g = gallop_lower_bound_counted(keys, from, key);
                assert_eq!(g.index, search::gallop_lower_bound(keys, from, key));
                // Galloping to an answer d positions away costs at most about
                // 2 * log2(d) + 2 comparisons, however long the array is.
                let distance = g.index - from;
                assert!(g.comparisons <= 2 * search::max_comparisons(distance) + 2);
            }
        }
    }
}
