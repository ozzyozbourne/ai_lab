//! A Bloom filter: the per-run membership filter of an LSM-tree.
//!
//! A filter is a bit array plus `HASH_COUNT` hash functions. Adding a key
//! sets `HASH_COUNT` bits; asking for a key tests the same bits:
//!
//!   any bit clear  ->  the key was certainly never added   ("no")
//!   all bits set   ->  the key was added, OR other keys happened to set
//!                      all of its bits                     ("maybe")
//!
//! So a filter never loses a key (no false negatives), and it says "maybe"
//! for a small fraction of the keys that are absent: the FALSE-POSITIVE RATE.
//! With m bits for n keys and k hash functions that rate is about
//! (1 - e^(-k n / m))^k (textbook). The chapter uses m / n = 10 bits per
//! key and k = 7, which gives about 0.8%; the program prints the rate it
//! measured.
//!
//! Where it lives: in RAM, next to a run's min/max keys, like the filters of
//! real LSM engines. Asking it costs no block. It is built once, when the
//! run is complete, and dies with the run. Its price is that memory: 10 bits
//! per slot against the 128 bits of the slot itself.
//!
//! Invariant (checked by `Lsm::validate_structure`): every key of a run with
//! a filter answers "maybe".

/// Hash functions per key (k).
pub const HASH_COUNT: u64 = 7;

/// One 64-bit hash of the key: the output function of SplitMix64 (see
/// prng.rs). The same five lines in Zig and Rust, so both build the same
/// filters bit for bit.
pub fn hash(key: u64) -> u64 {
    let mut z = key.wrapping_add(0x9E37_79B9_7F4A_7C15);
    z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
    z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
    z ^ (z >> 31)
}

#[derive(Debug, Default)]
pub struct Filter {
    /// The bit array, 64 bits per word. Empty: the run has no filter.
    /// (Public so that the tests can damage a filter and watch `validate`.)
    pub words: Vec<u64>,
    /// Bits in use (m). 0 until `seal`, and for a run without a filter;
    /// then every key answers "maybe".
    bits: usize,
}

impl Filter {
    pub fn words_for(keys: usize, bits_per_key: usize) -> usize {
        (keys * bits_per_key).div_ceil(64)
    }

    /// Reserves room for `max_keys` keys. This is the filter's ONLY
    /// allocation; `bits_per_key == 0` means "no filter" and allocates
    /// nothing. (In the Zig version this allocation can fail; here the
    /// builder's slot budget stands in for both of its allocations.)
    pub fn with_capacity(max_keys: usize, bits_per_key: usize) -> Filter {
        Filter {
            words: vec![0; Self::words_for(max_keys, bits_per_key)],
            bits: 0,
        }
    }

    /// Bits of RAM in use; 0 for "no filter".
    pub fn bits(&self) -> usize {
        self.bits
    }

    /// Fixes the size, now that the number of keys is known (a compaction
    /// may write fewer slots than it reserved for). Call before `add`.
    pub fn seal(&mut self, keys: usize, bits_per_key: usize) {
        if self.words.is_empty() {
            return;
        }
        assert!(keys > 0 && self.bits == 0);
        let used = Self::words_for(keys, bits_per_key);
        assert!(used <= self.words.len());
        self.bits = keys * bits_per_key;
        // Give the surplus back.
        self.words.truncate(used);
        self.words.shrink_to_fit();
    }

    /// The i-th bit position of a key: "double hashing". The two halves of
    /// one 64-bit hash stand in for `HASH_COUNT` independent hash functions.
    fn position(&self, h: u64, i: u64) -> usize {
        let h1 = h & 0xffff_ffff;
        let h2 = (h >> 32) | 1; // odd, so the steps do not all coincide
        ((h1 + i * h2) % self.bits as u64) as usize
    }

    pub fn add(&mut self, key: u64) {
        if self.bits == 0 {
            return;
        }
        let h = hash(key);
        for i in 0..HASH_COUNT {
            let p = self.position(h, i);
            self.words[p / 64] |= 1 << (p % 64);
        }
    }

    /// false: certainly absent. true: present, or a false positive.
    pub fn may_contain(&self, key: u64) -> bool {
        if self.bits == 0 {
            return true;
        }
        let h = hash(key);
        (0..HASH_COUNT).all(|i| {
            let p = self.position(h, i);
            self.words[p / 64] & (1 << (p % 64)) != 0
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_filter_never_says_no_for_a_key_it_holds_and_rarely_says_maybe_for_others() {
        let mut f = Filter::with_capacity(1200, 10);
        f.seal(1000, 10); // fewer keys than reserved, as after a compaction
        assert_eq!(f.bits(), 10_000);
        assert_eq!(f.words.len(), 157);
        for i in 0..1000 {
            f.add(i * 3);
        }
        assert!((0..1000).all(|i| f.may_contain(i * 3)));
        // 100000 absent keys: about 0.8% expected for 10 bits per key, 7 hashes.
        let false_positives = (0..100_000).filter(|i| f.may_contain(i * 3 + 1)).count();
        assert_eq!(false_positives, 838); // the same count in Zig
    }

    #[test]
    fn a_filter_with_too_few_bits_still_never_loses_a_key() {
        let mut f = Filter::with_capacity(50, 1);
        f.seal(50, 1);
        let key = |i: u64| i.wrapping_mul(0x9E37_79B9_7F4A_7C15);
        for i in 0..50 {
            f.add(key(i));
        }
        assert!((0..50).all(|i| f.may_contain(key(i))));
        // The extreme keys hash like any other.
        f.add(0);
        f.add(u64::MAX);
        assert!(f.may_contain(0) && f.may_contain(u64::MAX));
    }

    #[test]
    fn no_filter_no_allocation_and_every_key_answers_maybe() {
        let mut f = Filter::with_capacity(100, 0);
        assert_eq!(f.words.capacity(), 0);
        f.seal(100, 0);
        f.add(1);
        assert!(f.may_contain(1) && f.may_contain(2));
        assert_eq!(f.bits(), 0);
    }

    #[test]
    fn hash_is_the_splitmix64_output_function() {
        // First output of SplitMix64 seeded with 0 (common/golden.txt).
        assert_eq!(hash(0), 0xE220_A839_7B1D_CDAF);
    }
}
