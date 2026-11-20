//! Zone map: one (min, max) summary per fixed-size chunk of a column.
//!
//! A B+tree's inner node says "every key in child i lies between separator
//! i-1 and separator i", and the separators are sorted, so one binary search
//! picks one child. A zone map keeps only the first half of that sentence.
//! The chunks are in arrival order, their ranges may overlap, and so every
//! summary has to be tested: the cost is O(chunks), not O(log chunks). What
//! it buys is that nothing has to be kept sorted.

/// What a summary can prove about a predicate over a whole chunk.
/// DuckDB calls these FILTER_ALWAYS_TRUE, FILTER_ALWAYS_FALSE and
/// NO_PRUNING_POSSIBLE (duckdb/src/storage/statistics/numeric_stats.cpp:209).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Prune {
    /// Every row matches: count the chunk, do not look at its rows.
    AlwaysTrue,
    /// No row can match: skip the chunk.
    AlwaysFalse,
    /// The summary cannot decide: compare every row.
    Maybe,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Op {
    Eq,
    Ne,
    Lt,
    Le,
    Gt,
    Ge,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Zone {
    pub min: u64,
    pub max: u64,
    /// Rows summarised. Never 0: a zone is created by its first row.
    pub count: u32,
}

/// Pick a verdict from "true for all rows?" and "true for some row?".
fn verdict(all: bool, some: bool) -> Prune {
    if all {
        Prune::AlwaysTrue
    } else if some {
        Prune::Maybe
    } else {
        Prune::AlwaysFalse
    }
}

/// The three-way test for `value <op> c`. Each arm reads as: "is the
/// predicate true for all rows?" and "can it be true for some row?".
pub fn check_zone(zone: Zone, op: Op, c: u64) -> Prune {
    let inside = zone.min <= c && c <= zone.max;
    let single = zone.min == c && zone.max == c; // every row equals c
    match op {
        Op::Eq => verdict(single, inside),
        Op::Ne => verdict(!inside, !single),
        // v >= c: all rows match if the smallest does, none if the largest does not.
        Op::Ge => verdict(zone.min >= c, zone.max >= c),
        Op::Gt => verdict(zone.min > c, zone.max > c),
        Op::Le => verdict(zone.max <= c, zone.min <= c),
        Op::Lt => verdict(zone.max < c, zone.min < c),
    }
}

/// Combine the verdicts of two predicates joined by AND.
pub fn and_prune(a: Prune, b: Prune) -> Prune {
    if a == Prune::AlwaysFalse || b == Prune::AlwaysFalse {
        Prune::AlwaysFalse
    } else if a == Prune::AlwaysTrue && b == Prune::AlwaysTrue {
        Prune::AlwaysTrue
    } else {
        Prune::Maybe
    }
}

pub fn compare(v: u64, op: Op, c: u64) -> bool {
    match op {
        Op::Eq => v == c,
        Op::Ne => v != c,
        Op::Lt => v < c,
        Op::Le => v <= c,
        Op::Gt => v > c,
        Op::Ge => v >= c,
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Filter {
    Cmp {
        op: Op,
        c: u64,
    },
    /// lo <= v <= hi, both ends inclusive.
    Between {
        lo: u64,
        hi: u64,
    },
}

impl Filter {
    pub fn matches(self, v: u64) -> bool {
        match self {
            Filter::Cmp { op, c } => compare(v, op, c),
            Filter::Between { lo, hi } => lo <= v && v <= hi,
        }
    }

    pub fn check(self, zone: Zone) -> Prune {
        match self {
            Filter::Cmp { op, c } => check_zone(zone, op, c),
            Filter::Between { lo, hi } => {
                and_prune(check_zone(zone, Op::Ge, lo), check_zone(zone, Op::Le, hi))
            }
        }
    }
}

#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
pub struct ScanStats {
    pub chunks_skipped: u32, // AlwaysFalse
    pub chunks_all: u32,     // AlwaysTrue
    pub chunks_scanned: u32, // Maybe
    pub rows_compared: u64,
    pub matches: u64,
}

/// Rust's stand-in for Zig's `error.OutOfMemory`: `Vec` aborts the process
/// when memory runs out, so the failure path is modelled with a row budget.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct OutOfRows;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Invalid;

#[derive(Debug)]
pub struct ZoneMap {
    chunk_size: u32,
    /// Maximum number of rows (`usize::MAX` = unlimited).
    budget: usize,
    values: Vec<u64>,
    /// zones[i] summarises values[i * chunk_size ..][..count].
    zones: Vec<Zone>,
}

impl ZoneMap {
    pub fn new(chunk_size: u32) -> Self {
        Self::with_budget(chunk_size, usize::MAX)
    }

    pub fn with_budget(chunk_size: u32, budget: usize) -> Self {
        assert!(chunk_size > 0);
        Self {
            chunk_size,
            budget,
            values: Vec::new(),
            zones: Vec::new(),
        }
    }

    pub fn values(&self) -> &[u64] {
        &self.values
    }

    pub fn zones(&self) -> &[Zone] {
        &self.zones
    }

    /// Append one row. The only maintenance a zone map ever needs: widen the
    /// last zone, or open a new one. The budget is checked before anything
    /// changes, so a failed append leaves the map exactly as it was.
    pub fn append(&mut self, v: u64) -> Result<(), OutOfRows> {
        if self.values.len() >= self.budget {
            return Err(OutOfRows);
        }
        self.values.push(v);
        if let Some(last) = self.zones.last_mut()
            && last.count < self.chunk_size
        {
            last.min = last.min.min(v);
            last.max = last.max.max(v);
            last.count += 1;
            return Ok(());
        }
        self.zones.push(Zone {
            min: v,
            max: v,
            count: 1,
        });
        Ok(())
    }

    pub fn append_slice(&mut self, vs: &[u64]) -> Result<(), OutOfRows> {
        vs.iter().try_for_each(|&v| self.append(v))
    }

    fn chunk(&self, i: usize) -> &[u64] {
        let start = i * self.chunk_size as usize;
        &self.values[start..start + self.zones[i].count as usize]
    }

    /// Count the rows that match `filter`. Every zone is tested (no order to
    /// exploit), but rows are only touched in the `Maybe` chunks.
    pub fn scan(&self, filter: Filter) -> ScanStats {
        let mut stats = ScanStats::default();
        for (i, &zone) in self.zones.iter().enumerate() {
            match filter.check(zone) {
                Prune::AlwaysFalse => stats.chunks_skipped += 1,
                Prune::AlwaysTrue => {
                    stats.chunks_all += 1;
                    stats.matches += u64::from(zone.count);
                }
                Prune::Maybe => {
                    stats.chunks_scanned += 1;
                    for &v in self.chunk(i) {
                        stats.rows_compared += 1;
                        if filter.matches(v) {
                            stats.matches += 1;
                        }
                    }
                }
            }
        }
        stats
    }

    /// Invariants: every zone but the last is full, the counts add up to the
    /// row count, and each (min, max) is exactly the chunk's min and max.
    /// (A real engine only needs min <= every row <= max; deletes leave the
    /// bounds wider than necessary, which is still correct.)
    pub fn validate(&self) -> Result<(), Invalid> {
        let mut rows = 0usize;
        for (i, zone) in self.zones.iter().enumerate() {
            let is_last = i + 1 == self.zones.len();
            if zone.count == 0 || zone.count > self.chunk_size {
                return Err(Invalid);
            }
            if !is_last && zone.count != self.chunk_size {
                return Err(Invalid);
            }
            rows += zone.count as usize;
            if rows > self.values.len() {
                return Err(Invalid);
            }
            let chunk = self.chunk(i);
            let lo = chunk.iter().copied().min();
            let hi = chunk.iter().copied().max();
            if Some(zone.min) != lo || Some(zone.max) != hi {
                return Err(Invalid);
            }
        }
        if rows != self.values.len() {
            return Err(Invalid);
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::prng::SplitMix64;

    const OPS: [Op; 6] = [Op::Eq, Op::Ne, Op::Lt, Op::Le, Op::Gt, Op::Ge];

    #[test]
    fn check_zone_every_operator_every_position_of_the_constant() {
        use Prune::{AlwaysFalse as F, AlwaysTrue as T, Maybe as M};
        let z = Zone {
            min: 10,
            max: 20,
            count: 5,
        };
        // constant below, at min, inside, at max, above
        let cs = [5, 10, 15, 20, 25];
        let want = [
            [F, M, M, M, F], // eq
            [T, M, M, M, T], // ne
            [F, F, M, M, T], // lt
            [F, M, M, T, T], // le
            [T, M, M, F, F], // gt
            [T, T, M, M, F], // ge
        ];
        for (op, row) in OPS.into_iter().zip(want) {
            for (c, expected) in cs.into_iter().zip(row) {
                assert_eq!(check_zone(z, op, c), expected, "{op:?} {c}");
            }
        }
        // A chunk holding one distinct value can decide = and != completely.
        let one = Zone {
            min: 7,
            max: 7,
            count: 3,
        };
        assert_eq!(check_zone(one, Op::Eq, 7), T);
        assert_eq!(check_zone(one, Op::Ne, 7), F);
    }

    #[test]
    fn between_combines_two_one_sided_checks() {
        let z = Zone {
            min: 10,
            max: 20,
            count: 5,
        };
        let f = |lo, hi| Filter::Between { lo, hi }.check(z);
        assert_eq!(f(10, 20), Prune::AlwaysTrue);
        assert_eq!(f(0, 99), Prune::AlwaysTrue);
        assert_eq!(f(15, 99), Prune::Maybe);
        assert_eq!(f(21, 99), Prune::AlwaysFalse);
        assert_eq!(f(0, 9), Prune::AlwaysFalse);
    }

    #[test]
    fn model_test_pruned_scan_equals_brute_force_verdicts_are_sound() {
        let mut rng = SplitMix64::new(29);
        for round in 0..40u64 {
            let mut zm = ZoneMap::new(1 + rng.below(40) as u32);
            let n = rng.below(600);
            // Even rounds: nearly sorted (zones are narrow). Odd rounds: random.
            for i in 0..n {
                let v = if round % 2 == 0 {
                    i / 3 + rng.below(8)
                } else {
                    rng.below(200)
                };
                zm.append(v).unwrap();
            }
            zm.validate().unwrap();
            for _ in 0..60 {
                let a = rng.below(220);
                let filter = match rng.below(7) {
                    0 => Filter::Between {
                        lo: a,
                        hi: a + rng.below(50),
                    },
                    k => Filter::Cmp {
                        op: OPS[k as usize - 1],
                        c: a,
                    },
                };
                // Oracle: look at every row.
                let want = zm.values().iter().filter(|&&v| filter.matches(v)).count() as u64;
                let got = zm.scan(filter);
                assert_eq!(got.matches, want);
                assert_eq!(
                    (got.chunks_skipped + got.chunks_all + got.chunks_scanned) as usize,
                    zm.zones().len()
                );
                // Soundness of each verdict, chunk by chunk.
                for (i, zone) in zm.zones().iter().enumerate() {
                    let hits = zm.chunk(i).iter().filter(|&&v| filter.matches(v)).count() as u32;
                    match filter.check(*zone) {
                        Prune::AlwaysTrue => assert_eq!(hits, zone.count),
                        Prune::AlwaysFalse => assert_eq!(hits, 0),
                        Prune::Maybe => {}
                    }
                }
            }
        }
    }

    #[test]
    fn validate_catches_a_stale_summary() {
        let mut zm = ZoneMap::new(4);
        zm.append_slice(&[5, 9, 7, 6, 30]).unwrap();
        zm.validate().unwrap();
        zm.values[1] = 99; // update in place without widening the zone
        assert_eq!(zm.validate(), Err(Invalid));
        // ... and the stale zone now gives a wrong answer: this is why validate exists.
        assert_eq!(zm.scan(Filter::Cmp { op: Op::Eq, c: 99 }).matches, 0);
    }

    #[test]
    fn append_over_budget_leaves_a_valid_map() {
        // Mirror of the Zig allocation-failure test: fail at every possible row.
        for budget in 0..40 {
            let mut zm = ZoneMap::with_budget(3, budget);
            for i in 0..40u64 {
                match zm.append(i * 7 % 11) {
                    Ok(()) => {}
                    Err(OutOfRows) => {
                        // The failed append must not have half-happened.
                        assert_eq!(zm.values().len(), i as usize);
                        assert_eq!(i as usize, budget);
                        break;
                    }
                }
            }
            zm.validate().unwrap();
        }
    }
}
