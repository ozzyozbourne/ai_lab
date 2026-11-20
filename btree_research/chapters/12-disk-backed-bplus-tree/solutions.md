# Chapter 12: solutions

Numbers below come from this chapter's own code. Where something was not run, it says so.

## 1. How many cells fit

A page offers 4076 bytes. A cell costs `4 + key + value + 2`.

- 4-byte key, 1000-byte value: 1010 bytes. `4 * 1010 = 4040 <= 4076`, `5 * 1010 = 5050`: four fit.
- 4-byte key, 8-byte value: 18 bytes. `226 * 18 = 4068 <= 4076`, `227 * 18 = 4086`: 226 fit.

The test "full is a number of bytes, not a number of keys" (both languages) inserts exactly
that many cells, checks that no split happened, inserts one more and checks that one did.

## 2. `max_value_len = 2000`

Run: the build fails. In Zig the `comptime` block in `disk_btree.zig` reaches
`assert(3 * cellCost(max_key_len, max_value_len) <= page_capacity)` and the compiler reports
"reached unreachable code" for that assertion. (The Rust twin is a `const _: () = assert!(...)`;
it was not rebuilt with the changed constant for this answer.)

The step that would break: "the left half is below `T/2 + m`, which is at most `C`". With
`m = 4 + 256 + 2000 + 2 = 2262` that bound is `C/2 + 3m/2 = 5431`, above `C = 4076`. A
concrete case (arithmetic, not run): a leaf holds cells of 2262 and 1700 bytes (3962 in
total) and a new cell of 2262 bytes sorts between them. The costs in key order are 2262, 2262,
1700, so `T = 6224` and half is 3112. The shortest prefix with at least 3112 bytes is the
first two cells, 4524 bytes, which does not fit in a page. `writeLeaf`'s
`insertAt(...) catch unreachable` would be reached. (A cleverer cut, 2262 | 3962, exists
here; the point of `m <= C/3` is that the simple rule is then right for every input.)

## 3. Part 4 with a 3-frame pool

Run (the pool size in `crashDuringSplit` changed from 8 to 3, then changed back):

```
N = 0: validate ok; 11 of 11 old keys readable; new key missing
N = 1: validate fails with error.UnreachablePage; 11 of 11 old keys readable; new key missing
N = 2: validate fails with error.KeyOutOfBounds; 9 of 11 old keys readable; new key missing
N = 3: validate fails with error.BadPage; 9 of 11 old keys readable; new key missing
N = 4: validate fails with error.KeyCountMismatch; 11 of 11 old keys readable; new key readable
N = 5: no crash, all writes done; validate ok; 11 of 11 old keys readable; new key readable
```

Still five writes, but in a different order and at different times. With three frames the
pool must evict during the put, so tree pages reach the file before `flush` is even called,
and the metapage goes last instead of first. That is why N = 4 is a new case: every tree page
is written and the new key is readable, but page 0 still says 11 keys and 4 pages. The data
is all there and `validate` still fails. The order in which a buffer pool writes pages is an
accident of its eviction policy; nothing in this chapter controls it. Chapter 22 does.

## 4. Ascending versus random inserts

Run (1000 keys of 8 bytes, 100-byte values, cell cost 114, 8-frame pool):

| order | leaves | average bytes per leaf (of 4076) |
|---|---|---|
| ascending | 55 | 2072 |
| random | 41 | 2780 |

With ascending keys every insert goes to the rightmost leaf. When it splits 50/50, the left
half is never touched again, so every leaf except the last stays half full: about 51%.
Random inserts keep filling old leaves after they split, which gives about 68% here. Chapter 14
shows the fix real engines use (leave the left page full when the insert is at the right
edge) and why Turso's `balance_quick` exists.

## 5. A put that cannot leave a half-split tree in memory

Not implemented; this is a design sketch, not measured.

A step can fail in three ways: a fetch (read error, or the write-back of the evicted page
fails), a page allocation, or scratch memory. To make the whole put all-or-nothing, everything
that can fail must happen before the first byte changes:

1. Walk up the remembered path and decide, level by level, whether that level will split.
   That needs the separator each level would hand up, which needs the split points, so the
   split points must be computed first (on copies, without changing pages).
2. Pin every page that will change: per splitting level the page and its new sibling, plus
   the first parent that does not split, plus one extra page if the root moves down. Allocate
   all new pages now.
3. Only then modify, which can no longer fail, and unpin everything.

The pin count grows from 2 to about `2 * (levels that split) + 2`, so a 2-frame pool no longer
works, and a failed attempt leaves allocated but unused pages at the end of the file unless
the allocation can be undone. This is the same problem a write-ahead log solves from the other
side: instead of making sure nothing can fail, it makes a failure in the middle repairable.
