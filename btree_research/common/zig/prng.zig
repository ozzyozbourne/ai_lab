//! SplitMix64: a tiny, fast, deterministic pseudo-random number generator.
//!
//! Source of truth: common/zig/prng.zig (twin: common/rust/prng.rs).
//! A chapter copies this file and adds as its first line:
//!     // Copied from common/zig/prng.zig; do not edit here
//!
//! Why SplitMix64? The whole generator is one u64 of state and five lines of
//! wrapping integer arithmetic, so the Zig and Rust versions produce exactly
//! the same numbers (see common/golden.txt). NOT for cryptography.
const std = @import("std");

pub const SplitMix64 = struct {
    state: u64,

    /// Any seed is fine, including 0.
    pub fn init(seed: u64) SplitMix64 {
        return .{ .state = seed };
    }

    /// Next 64 random bits. `+%` and `*%` are wrapping (mod 2^64) operators.
    pub fn nextU64(self: *SplitMix64) u64 {
        self.state +%= 0x9E3779B97F4A7C15;
        var z = self.state;
        z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
        z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
        return z ^ (z >> 31);
    }

    /// Uniform-enough integer in [0, n). Requires n > 0.
    ///
    /// Method: "multiply-high". Take the top 64 bits of the 128-bit product
    /// `nextU64() * n`. Think of nextU64()/2^64 as a fraction in [0, 1) that
    /// is scaled by n. No loop, no division, exactly one nextU64() per call.
    /// The bias is at most n / 2^64, which is invisible for test workloads.
    pub fn below(self: *SplitMix64, n: u64) u64 {
        std.debug.assert(n > 0);
        const wide = @as(u128, self.nextU64()) * @as(u128, n);
        return @intCast(wide >> 64);
    }

    /// Integer in the half-open interval [lo, hi). Requires lo < hi.
    pub fn range(self: *SplitMix64, lo: u64, hi: u64) u64 {
        std.debug.assert(lo < hi);
        return lo + self.below(hi - lo);
    }

    /// True with probability numerator/denominator (e.g. chance(1, 4) = 25%).
    /// Requires denominator > 0. Always consumes exactly one nextU64().
    pub fn chance(self: *SplitMix64, numerator: u64, denominator: u64) bool {
        return self.below(denominator) < numerator;
    }

    /// Fisher-Yates shuffle, in place. Walks i from the last index down to 1
    /// and swaps items[i] with items[j], j = below(i + 1). The loop direction
    /// is part of the contract: Rust does exactly the same.
    pub fn shuffle(self: *SplitMix64, items: []u64) void {
        var i = items.len;
        while (i > 1) {
            i -= 1;
            const j: usize = @intCast(self.below(i + 1));
            std.mem.swap(u64, &items[i], &items[j]);
        }
    }
};

test "SplitMix64 reference outputs for seed 0" {
    var rng = SplitMix64.init(0);
    try std.testing.expectEqual(0xE220A8397B1DCDAF, rng.nextU64());
    try std.testing.expectEqual(0x6E789E6AA1B965F4, rng.nextU64());
    try std.testing.expectEqual(0x06C45D188009454F, rng.nextU64());
}

test "below, range and chance stay in bounds" {
    var rng = SplitMix64.init(42);
    for (0..1000) |_| {
        try std.testing.expect(rng.below(7) < 7);
        const r = rng.range(10, 13);
        try std.testing.expect(r >= 10 and r < 13);
        try std.testing.expectEqual(0, rng.below(1));
        try std.testing.expect(!rng.chance(0, 5));
        try std.testing.expect(rng.chance(5, 5));
    }
    // n = 2^64 - 1 must not overflow.
    _ = rng.below(std.math.maxInt(u64));
}

test "shuffle is a permutation and is deterministic" {
    var a = [_]u64{ 0, 1, 2, 3, 4, 5, 6, 7 };
    var b = a;
    var r1 = SplitMix64.init(7);
    var r2 = SplitMix64.init(7);
    r1.shuffle(&a);
    r2.shuffle(&b);
    try std.testing.expectEqualSlices(u64, &a, &b);
    var sum: u64 = 0;
    for (a) |x| sum += x;
    try std.testing.expectEqual(28, sum);
    var empty = [_]u64{};
    r1.shuffle(&empty); // must not crash
}
