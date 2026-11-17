# Chapter 02: solutions

The code below is Zig; every snippet was compiled and tested against the chapter's
functions (exhaustively where the exercise asks for it). The Rust versions are
line-for-line translations.

The node used throughout:

```
index:   0   1   2   3   4   5   6   7   8   9  10  11
key:     1   3   5   6   7  10  12  15  17  20  25  30
```

## 1. Traces by hand

`lowerBound(6)` (test: `keys[mid] < 6`):

| step | lo | hi | mid | keys[mid] | test | action |
|------|----|----|-----|-----------|------|--------|
| 1 | 0 | 12 | 6 | 12 | false | `hi = 6` |
| 2 | 0 | 6 | 3 | 6 | false | `hi = 3` |
| 3 | 0 | 3 | 1 | 3 | true | `lo = 2` |
| 4 | 2 | 3 | 2 | 5 | true | `lo = 3` |

Index 3, 4 comparisons. `keys[3] == 6`, so `search` reports `{found = true, index = 3}`.
Note step 2: the loop saw the key itself and did **not** stop. It cannot know yet that
there is no other 6 to the left.

`upperBound(6)` (test: `keys[mid] <= 6`):

| step | lo | hi | mid | keys[mid] | test | action |
|------|----|----|-----|-----------|------|--------|
| 1 | 0 | 12 | 6 | 12 | false | `hi = 6` |
| 2 | 0 | 6 | 3 | 6 | true | `lo = 4` |
| 3 | 4 | 6 | 5 | 10 | false | `hi = 5` |
| 4 | 4 | 5 | 4 | 7 | false | `hi = 4` |

Index 4, 4 comparisons: one past the 6. `upperBound - lowerBound = 1` copy of the key.

`lowerBound(31)`:

| step | lo | hi | mid | keys[mid] | test | action |
|------|----|----|-----|-----------|------|--------|
| 1 | 0 | 12 | 6 | 12 | true | `lo = 7` |
| 2 | 7 | 12 | 9 | 20 | true | `lo = 10` |
| 3 | 10 | 12 | 11 | 30 | true | `lo = 12` |

Index 12, 3 comparisons. 12 is `keys.len`: there is no element there, so `search`
must test `index < keys.len` before reading `keys[index]`, and reports
`{found = false, index = 12}` (append at the end).

## 2. `countInRange`

```zig
fn countInRange(keys: []const u64, lo: u64, hi: u64) usize {
    const start = lowerBound(keys, lo); // first key >= lo
    const end = upperBound(keys, hi); // first key >  hi
    return if (end > start) end - start else 0;
}
```

On the node, `countInRange(5, 17)` is `9 - 2 = 7`.

When `lo > hi` no key can satisfy `lo <= k <= hi`, so the answer must be 0. Without the
`if` it is not: for `lo = 20, hi = 5` the node gives `start = 9` and `end = 3`, and
`3 - 9` underflows (a panic in debug builds, a huge number otherwise). So the special
case is needed, in the form of a clamp. It is the same clamp as in `rangeSpan`.

A range that is merely empty of keys needs no special case: `countInRange(8, 9)` gives
`start = end = 5`.

## 3. Closed interval with a remembered candidate

```zig
fn lowerBoundClosed(keys: []const u64, key: u64) usize {
    var min: isize = 0;
    var max: isize = @as(isize, @intCast(keys.len)) - 1;
    var nearest: ?usize = null;
    while (min <= max) {
        const mid = min + @divFloor(max - min, 2);
        const i: usize = @intCast(mid);
        if (keys[i] >= key) {
            nearest = i; // best answer so far; look for a better one on the left
            max = mid - 1;
        } else {
            min = mid + 1;
        }
    }
    return nearest orelse keys.len;
}
```

Invariant:

```
keys[0..min]    are all <  key
keys[max+1..]   are all >= key
nearest         is null if keys[max+1..] is empty, otherwise it is max + 1
```

`min..=max` is the unknown region, now with both ends inclusive, so it is empty when
`min > max` (hence `<=` in the loop condition, and `max` starts at `len - 1`). In the
half-open version `hi` did two jobs: it bounded the unknown region and it *was* the
candidate answer. Here `max` moves to `mid - 1`, past the candidate, so the candidate
must be saved separately; that is the role of Turso's `nearest_matching_cell`, and "no
candidate" is the case where Turso follows the right-most child pointer.

Two things to notice:

- `max` becomes -1 when the first element qualifies (and starts at -1 for an empty
  array), so the indices must be signed, or every `mid - 1` must be guarded.
- It probes different midpoints but has the same worst case (as many comparisons as
  `n` has binary digits), so neither is faster. The half-open form has one variable
  fewer and no signed arithmetic, which is why this chapter uses it.

The function passes the exhaustive test (all 330 sorted arrays of length 0 to 7, keys
0 to 8) against `lowerBound`.

## 4. Choosing a child

Separators `10, 20`, three children:

| convention | child 0 | child 1 | child 2 | child index |
|------------|---------|---------|---------|-------------|
| `s[i-1] <= k < s[i]` | `k < 10` | `10 <= k < 20` | `20 <= k` | `upperBound(s, k)` |
| `s[i-1] < k <= s[i]` | `k <= 10` | `10 < k <= 20` | `20 < k` | `lowerBound(s, k)` |

| key | `upperBound` | `lowerBound` |
|-----|--------------|--------------|
| 5 | 0 | 0 |
| 10 | 1 | 0 |
| 15 | 1 | 1 |
| 20 | 2 | 1 |
| 25 | 2 | 2 |

Reasoning for the first convention: the child index is the number of separators that
are `<= k` (each such separator pushes the key one child to the right), and "number of
elements `<= k`" is the definition of the upper bound. For the second convention it is
the number of separators `< k`, the lower bound.

The two only differ when the key equals a separator, which is exactly the case a
hand-made test tends to miss and the exhaustive test always includes. Chapter 03 picks
one convention and keeps it; Postgres's variant of the same choice is the
`OffsetNumberPrev(low)` at the end of `_bt_binsrch`.

## 5. Partition point

```zig
/// Index of the first element for which `pred` is false, or keys.len.
fn partitionPoint(
    keys: []const u64,
    context: anytype,
    comptime pred: fn (@TypeOf(context), u64) bool,
) usize {
    var lo: usize = 0;
    var hi: usize = keys.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (pred(context, keys[mid])) lo = mid + 1 else hi = mid;
    }
    return lo;
}

fn lessThan(key: u64, k: u64) bool {
    return k < key;
}
fn lessOrEqual(key: u64, k: u64) bool {
    return k <= key;
}

// lowerBound(keys, key) == partitionPoint(keys, key, lessThan)
// upperBound(keys, key) == partitionPoint(keys, key, lessOrEqual)
```

Galloping is the same generalisation: replace `keys[i] >= key` by `!pred(keys[i])` and
finish with `partitionPoint` on the bracket.

```zig
fn gallopPartitionPoint(
    keys: []const u64,
    from: usize,
    context: anytype,
    comptime pred: fn (@TypeOf(context), u64) bool,
) usize {
    if (from == keys.len or !pred(context, keys[from])) return from;
    var below = from; // invariant: pred(keys[below]) is true
    var step: usize = 1;
    var hi = keys.len;
    while (step < keys.len - below) {
        const probe = below + step;
        if (!pred(context, keys[probe])) {
            hi = probe;
            break;
        }
        below = probe;
        step *= 2;
    }
    const first = below + 1;
    return first + partitionPoint(keys[first..hi], context, pred);
}
```

**The property.** The array must be *partitioned* by `pred`: every element for which
`pred` is true comes before every element for which it is false (true, true, ..., true,
false, ..., false). That is all binary search ever needed; the invariant is just
"`keys[0..lo]` are true, `keys[hi..]` are false". A sorted array is partitioned by
`k < key` and by `k <= key` for every `key`, which is why sortedness is the usual
precondition, but it is stronger than necessary.

**The counterexample.** `keys = 1 2 3 4 5` with `pred` = "the key is odd". The first
element for which the predicate is false is the 2 at index 1. The loop probes index 2
(3, odd, `lo = 3`) and then index 4 (5, odd, `lo = 5`) and returns 5. The predicate
flips back and forth, so "everything left of a true probe is true" is not a fact about
this array, and the invariant was broken at the first step. Nothing crashes and nothing
warns; the answer is simply wrong. This is the general form of pitfall 7 in the
chapter (searching an unsorted array).

Rust has this function as `slice::partition_point`, Zig as `std.sort.partitionPoint`.
