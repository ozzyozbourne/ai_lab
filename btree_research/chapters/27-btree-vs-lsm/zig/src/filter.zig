//! A Bloom filter: the per-run membership filter of an LSM-tree.
//!
//! A filter is a bit array plus `hash_count` hash functions. Adding a key
//! sets `hash_count` bits; asking for a key tests the same bits:
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
//! Invariant (checked by `Lsm.validateStructure`): every key of a run with a
//! filter answers "maybe".
const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

/// Hash functions per key (k).
pub const hash_count = 7;

/// One 64-bit hash of the key: the output function of SplitMix64 (see
/// prng.zig). The same five lines in Zig and Rust, so both build the same
/// filters bit for bit.
pub fn hash(key: u64) u64 {
    var z = key +% 0x9E3779B97F4A7C15;
    z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
    z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
    return z ^ (z >> 31);
}

pub const Filter = struct {
    /// The bit array, 64 bits per word. Empty: the run has no filter.
    words: []u64 = &.{},
    /// Bits in use (m). 0 until `seal`, and for a run without a filter;
    /// then every key answers "maybe".
    bits: usize = 0,

    pub fn wordsFor(keys: usize, bits_per_key: usize) usize {
        return std.math.divCeil(usize, keys * bits_per_key, 64) catch unreachable;
    }

    /// Reserves room for `max_keys` keys. This is the filter's ONLY
    /// allocation; `bits_per_key == 0` means "no filter" and allocates
    /// nothing.
    pub fn init(gpa: Allocator, max_keys: usize, bits_per_key: usize) Allocator.Error!Filter {
        const n = wordsFor(max_keys, bits_per_key);
        if (n == 0) return .{};
        const words = try gpa.alloc(u64, n);
        @memset(words, 0);
        return .{ .words = words };
    }

    pub fn deinit(self: *Filter, gpa: Allocator) void {
        gpa.free(self.words);
        self.* = .{};
    }

    /// Fixes the size, now that the number of keys is known (a compaction
    /// may write fewer slots than it reserved for). Call before `add`.
    pub fn seal(self: *Filter, gpa: Allocator, keys: usize, bits_per_key: usize) void {
        if (self.words.len == 0) return;
        assert(keys > 0 and self.bits == 0);
        const used = wordsFor(keys, bits_per_key);
        assert(used <= self.words.len);
        self.bits = keys * bits_per_key;
        // Give the surplus back if the allocator can shrink in place. If it
        // cannot, the filter keeps a few unused words: no error either way.
        if (gpa.resize(self.words, used)) self.words = self.words[0..used];
    }

    /// The i-th bit position of a key: "double hashing". The two halves of
    /// one 64-bit hash stand in for `hash_count` independent hash functions.
    fn position(self: *const Filter, h: u64, i: u64) usize {
        const h1 = h & 0xffff_ffff;
        const h2 = (h >> 32) | 1; // odd, so the steps do not all coincide
        return @intCast((h1 + i * h2) % self.bits);
    }

    pub fn add(self: *Filter, key: u64) void {
        if (self.bits == 0) return;
        const h = hash(key);
        for (0..hash_count) |i| {
            const p = self.position(h, i);
            self.words[p / 64] |= @as(u64, 1) << @intCast(p % 64);
        }
    }

    /// false: certainly absent. true: present, or a false positive.
    pub fn mayContain(self: *const Filter, key: u64) bool {
        if (self.bits == 0) return true;
        const h = hash(key);
        for (0..hash_count) |i| {
            const p = self.position(h, i);
            if (self.words[p / 64] & (@as(u64, 1) << @intCast(p % 64)) == 0) return false;
        }
        return true;
    }
};

test "a filter never says no for a key it holds, and rarely says maybe for others" {
    const gpa = std.testing.allocator;
    var f: Filter = try .init(gpa, 1200, 10);
    defer f.deinit(gpa);
    f.seal(gpa, 1000, 10); // fewer keys than reserved, as after a compaction
    try std.testing.expectEqual(10_000, f.bits);
    for (0..1000) |i| f.add(i * 3);
    for (0..1000) |i| try std.testing.expect(f.mayContain(i * 3));
    // 100000 absent keys: about 0.8% expected for 10 bits per key, 7 hashes.
    var false_positives: usize = 0;
    for (0..100_000) |i| false_positives += @intFromBool(f.mayContain(i * 3 + 1));
    try std.testing.expectEqual(838, false_positives); // the same count in Rust
}

test "a filter with too few bits still never loses a key" {
    const gpa = std.testing.allocator;
    var f: Filter = try .init(gpa, 50, 1);
    defer f.deinit(gpa);
    f.seal(gpa, 50, 1);
    for (0..50) |i| f.add(i *% 0x9E3779B97F4A7C15);
    for (0..50) |i| try std.testing.expect(f.mayContain(i *% 0x9E3779B97F4A7C15));
    // The extreme keys hash like any other.
    f.add(0);
    f.add(std.math.maxInt(u64));
    try std.testing.expect(f.mayContain(0) and f.mayContain(std.math.maxInt(u64)));
}

test "no filter: no allocation, and every key answers maybe" {
    var failing: std.testing.FailingAllocator = .init(std.testing.allocator, .{ .fail_index = 0 });
    const gpa = failing.allocator();
    var f: Filter = try .init(gpa, 100, 0);
    defer f.deinit(gpa);
    f.seal(gpa, 100, 0);
    f.add(1);
    try std.testing.expect(f.mayContain(1) and f.mayContain(2));
    try std.testing.expectEqual(0, f.bits);
}

test "hash is the SplitMix64 output function" {
    // First output of SplitMix64 seeded with 0 (common/golden.txt).
    try std.testing.expectEqual(0xE220A8397B1DCDAF, hash(0));
}
