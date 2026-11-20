//! SplitMix64: a tiny, fast, deterministic pseudo-random number generator.
//!
//! Source of truth: common/rust/prng.rs (twin: common/zig/prng.zig).
//! A chapter copies this file and adds as its first line:
//!     // Copied from common/rust/prng.rs; do not edit here
//!
//! Why SplitMix64? The whole generator is one u64 of state and five lines of
//! wrapping integer arithmetic, so the Zig and Rust versions produce exactly
//! the same numbers (see common/golden.txt). NOT for cryptography.

#[derive(Debug, Clone)]
pub struct SplitMix64 {
    state: u64,
}

impl SplitMix64 {
    /// Any seed is fine, including 0.
    pub fn new(seed: u64) -> Self {
        Self { state: seed }
    }

    /// Next 64 random bits. `wrapping_*` is arithmetic mod 2^64.
    pub fn next_u64(&mut self) -> u64 {
        self.state = self.state.wrapping_add(0x9E37_79B9_7F4A_7C15);
        let mut z = self.state;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        z ^ (z >> 31)
    }

    /// Uniform-enough integer in [0, n). Panics if n == 0.
    ///
    /// Method: "multiply-high". Take the top 64 bits of the 128-bit product
    /// `next_u64() * n`. Think of next_u64()/2^64 as a fraction in [0, 1)
    /// that is scaled by n. No loop, no division, exactly one next_u64() per
    /// call. The bias is at most n / 2^64, invisible for test workloads.
    pub fn below(&mut self, n: u64) -> u64 {
        assert!(n > 0, "below(0) is meaningless");
        ((u128::from(self.next_u64()) * u128::from(n)) >> 64) as u64
    }

    /// Integer in the half-open interval [lo, hi). Panics unless lo < hi.
    pub fn range(&mut self, lo: u64, hi: u64) -> u64 {
        assert!(lo < hi, "range needs lo < hi");
        lo + self.below(hi - lo)
    }

    /// True with probability numerator/denominator (chance(1, 4) = 25%).
    /// Panics if denominator == 0. Always consumes exactly one next_u64().
    pub fn chance(&mut self, numerator: u64, denominator: u64) -> bool {
        self.below(denominator) < numerator
    }

    /// Fisher-Yates shuffle, in place. Walks i from the last index down to 1
    /// and swaps items[i] with items[j], j = below(i + 1). The loop direction
    /// is part of the contract: Zig does exactly the same.
    pub fn shuffle(&mut self, items: &mut [u64]) {
        for i in (1..items.len()).rev() {
            let j = self.below(i as u64 + 1) as usize;
            items.swap(i, j);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reference_outputs_for_seed_0() {
        let mut rng = SplitMix64::new(0);
        assert_eq!(rng.next_u64(), 0xE220_A839_7B1D_CDAF);
        assert_eq!(rng.next_u64(), 0x6E78_9E6A_A1B9_65F4);
        assert_eq!(rng.next_u64(), 0x06C4_5D18_8009_454F);
    }

    #[test]
    fn below_range_and_chance_stay_in_bounds() {
        let mut rng = SplitMix64::new(42);
        for _ in 0..1000 {
            assert!(rng.below(7) < 7);
            assert!((10..13).contains(&rng.range(10, 13)));
            assert_eq!(rng.below(1), 0);
            assert!(!rng.chance(0, 5));
            assert!(rng.chance(5, 5));
        }
        // n = 2^64 - 1 must not overflow.
        let _ = rng.below(u64::MAX);
    }

    #[test]
    fn shuffle_is_a_permutation_and_is_deterministic() {
        let mut a: Vec<u64> = (0..8).collect();
        let mut b = a.clone();
        SplitMix64::new(7).shuffle(&mut a);
        SplitMix64::new(7).shuffle(&mut b);
        assert_eq!(a, b);
        let mut sorted = a.clone();
        sorted.sort_unstable();
        assert_eq!(sorted, (0..8).collect::<Vec<u64>>());
        SplitMix64::new(7).shuffle(&mut []); // must not panic
    }
}
