/* Chapter 25 code-panel snippets (classic script: no fetch under file://).
 * Simplified from zig/src/{search,layout}.zig and rust/src/{search,layout}.rs:
 * the `Select` switch is reduced to the hinted form and the prefetch lines are
 * shown inline (in the real code they sit behind a comptime / bool parameter).
 */
window.CHAPTER_CODE = {
  classic: {
    zig: `
pub fn lowerBoundClassic(keys: []const u64, key: u64, tracer: anytype) usize {
    var lo: usize = 0;
    var hi: usize = keys.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        tracer.cmp(mid);
        if (keys[mid] < key) { // a coin flip the CPU must guess
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    return lo;
}`,
    rust: `
pub fn lower_bound_classic<T: Tracer>(keys: &[u64], key: u64, tracer: &mut T) -> usize {
    let mut lo = 0;
    let mut hi = keys.len();
    while lo < hi {
        let mid = lo + (hi - lo) / 2;
        tracer.cmp(mid);
        if keys[mid] < key { // a coin flip the CPU must guess
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    lo
}`
  },
  halving: {
    zig: `
pub fn lowerBoundHalving(keys: []const u64, key: u64, tracer: anytype) usize {
    if (keys.len == 0) return 0;
    var offset: usize = 0;
    var length: usize = keys.len;
    while (length > 1) {
        const half = length / 2;
        const mid = offset + half;
        const next_half = (length - half) / 2; // prefetch variant only
        @prefetch(&keys[offset + next_half], .{});
        @prefetch(&keys[mid + next_half], .{});
        tracer.cmp(mid);
        offset = if (keys[mid] < key) blk: {
            @branchHint(.unpredictable); // ask for a conditional move
            break :blk mid;
        } else offset;
        length -= half; // always, whichever way the comparison went
    }
    tracer.cmp(offset);
    return offset + @intFromBool(keys[offset] < key);
}`,
    rust: `
pub fn lower_bound_halving<T: Tracer>(keys: &[u64], key: u64, tracer: &mut T) -> usize {
    if keys.is_empty() { return 0; }
    let mut offset = 0;
    let mut length = keys.len();
    while length > 1 {
        let half = length / 2;
        let mid = offset + half;
        let next_half = (length - half) / 2; // prefetch variant only
        tracer.prefetch(offset + next_half); // recorded only: stable Rust
        tracer.prefetch(mid + next_half);    // has no safe prefetch
        tracer.cmp(mid);
        offset = std::hint::select_unpredictable(keys[mid] < key, mid, offset);
        length -= half; // always, whichever way the comparison went
    }
    tracer.cmp(offset);
    offset + usize::from(keys[offset] < key)
}`
  },
  vector: {
    zig: `
pub fn rank8(block: *const [8]u64, key: u64) usize {
    const V = @Vector(8, u64);
    const smaller: @Vector(8, bool) = @as(V, block.*) < @as(V, @splat(key));
    return @popCount(@as(u8, @bitCast(smaller)));
}

pub fn lowerBoundVector(padded: []align(64) const u64, key: u64, tracer: anytype) usize {
    var count: usize = 0;
    var i: usize = 0;
    while (i < padded.len) : (i += 8) {
        tracer.cmpBlock(i, 8);
        count += rank8(padded[i..][0..8], key);
    }
    return count;
}`,
    rust: `
pub fn rank8(block: &[u64; 8], key: u64) -> usize {
    let mut count = 0;
    for &k in block { // fixed trip count, no early exit
        count += usize::from(k < key);
    }
    count
}

pub fn lower_bound_vector<T: Tracer>(padded: &AlignedKeys, key: u64, tracer: &mut T) -> usize {
    let mut count = 0;
    for (b, line) in padded.lines().iter().enumerate() {
        tracer.cmp_block(b * 8, 8);
        count += rank8(&line.0, key);
    }
    count
}`
  },
  eytzinger: {
    zig: `
pub fn lowerBound(self: *const Eytzinger, key: u64, tracer: anytype) usize {
    var k: usize = 1;
    while (k <= self.n) {
        const ahead = @min(8 * k, self.keys.len - 1); // prefetch variant only
        @prefetch(&self.keys[ahead], .{});
        tracer.cmp(k);
        k = 2 * k + @intFromBool(self.keys[k] < key);
    }
    k >>= @intCast(@ctz(~k) + 1); // undo the right turns and one left turn
    return self.rank[k];
}`,
    rust: `
pub fn lower_bound<T: Tracer>(&self, key: u64, tracer: &mut T) -> usize {
    let mut k = 1;
    while k <= self.n {
        let ahead = (8 * k).min(self.keys.len() - 1); // prefetch variant only
        tracer.prefetch(ahead); // recorded only
        tracer.cmp(k);
        k = 2 * k + usize::from(self.keys.get(k) < key);
    }
    k >>= k.trailing_ones() + 1; // undo the right turns and one left turn
    self.rank[k] as usize
}`
  },
  blocktree: {
    zig: `
pub fn lowerBound(self: *const BlockTree, key: u64, tracer: anytype) usize {
    var result: usize = self.n;
    var block: usize = 0;
    while (block < self.blockCount()) {
        tracer.cmpBlock(block * 8, 8);
        const r = search.rank8(self.keys[block * 8 ..][0..8], key);
        if (r < 8) result = self.rank[block * 8 + r];
        block = block * 9 + r + 1; // child r: arithmetic, no pointer
    }
    return result;
}`,
    rust: `
pub fn lower_bound<T: Tracer>(&self, key: u64, tracer: &mut T) -> usize {
    let mut result = self.n;
    let mut block = 0;
    while let Some(line) = self.keys.lines().get(block) {
        tracer.cmp_block(block * 8, 8);
        let r = rank8(&line.0, key);
        if r < 8 {
            result = self.rank[block * 8 + r] as usize;
        }
        block = block * 9 + r + 1; // child r: arithmetic, no pointer
    }
    result
}`
  }
};
