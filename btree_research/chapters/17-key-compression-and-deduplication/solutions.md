# Solutions: 17. Key compression and deduplication

## 1. Separators by hand

Pivot size = slot 2 + length 2 + key bytes + (6 if a TID is kept) + child 4.

| last on left | first on right | common prefix | separator | pivot bytes |
|---|---|---|---|---|
| `fig@5` | `grape@9` | (empty) | `"g"` | 2 + 2 + 1 + 4 = 9 |
| `grape@9` | `grapefruit@26` | `grape` | `"grapef"` | 2 + 2 + 6 + 4 = 14 |
| `date@3` | `date@8` | `date` (the whole key) | `"date"@3` | 2 + 2 + 4 + 6 + 4 = 18 |
| `a@1` | `b@1` | (empty) | `"b"` | 9 |

The second row shows the worst case for byte truncation when the left key is a prefix of
the right one: the separator is one byte longer than the left key. The third row is the
only one that needs a TID: no byte differs, so the last-left tuple is used in full.

## 2. Routing

The child index is the number of separators strictly below the search tuple `(key, 0)`.
A separator without a TID is below any tuple with the same key bytes.

| lookup | `"apr"` | `"c"` | `"cr"` | child |
|---|---|---|---|---|
| `apple` | above (`app` < `apr`) | above | above | 0 |
| `apr` | below (equal bytes, no TID) | above | above | 1 |
| `apricot` | below (prefix) | above | above | 1 |
| `c` | below | below (equal bytes, no TID) | above | 2 |
| `coconut` | below | below | above (`co` < `cr`) | 2 |
| `cr` | below | below | below | 3 |
| `zebra` | below | below | below | 3 |

The program prints the same for `c` and `coconut` in section 3 of its output.

## 3. Is the prefix the shortest separator?

For `banana` / `cherry` the result `c` is one byte; the only shorter string is the empty
one, and the empty string is not above `banana`. So no.

In general, let L < R be the two keys and n the length of their common prefix, and let S be
any valid separator, so L < S <= R as byte strings (ignore TIDs: they only matter when
L = R). Claim: S has at least n + 1 bytes. Proof: suppose S has at most n bytes. Since S <= R and R starts with the common
prefix P (n bytes), compare S with P. If S is a prefix of P, then S is a prefix of L as
well (L starts with P), so S <= L, contradicting L < S. Otherwise S and P differ at some
position i < len(S) <= n. If S[i] < P[i] then S < L (L starts with P). If S[i] > P[i] then
S > R (R starts with P). Both contradict L < S <= R. So every valid separator is longer
than n bytes, and `R[0..n+1]` has exactly n + 1: it is a shortest one.

It is not the only shortest one. For `banana` / `cherry`, `c` is the only 1-byte choice,
but for `banana` / `date` both `c` and `d` work. Choosing the prefix of the right key is
simply the easiest to compute.

## 4. Balance only

Change the score in `chooseLeafSplit` to ignore the separator (for example
`.{ 0, 0, imbalance }` for every legal cut). Workload B, truncation and deduplication on,
measured with that change:

| split rule | leaves | sep bytes | bytes/entry |
|---|---|---|---|
| shortest separator within 40..60% (chapter code) | 50 | 11.9 | 7.9 |
| most balanced cut | 49 | 13.5 | 7.4 |

Separators get longer because the balanced cut more often falls inside a run of equal keys,
where the separator must be the full key plus a TID (11 + 6 = 17 bytes) instead of a prefix.
The leaf count drops by one page: most of the gap to the 45 leaves of "dedup" alone is
therefore not caused by the split rule but by the different fence sizes changing which
pages split. With about 50 leaves, a few pages either way is not a trend. The lesson of
Postgres's design holds at any scale, though: look for a short separator only among cuts
that are close to balanced, never at any price.

## 5. Prefix compression

Sketch:

- `prefix_len(page) = commonPrefixLen(low.key, high.key)` if both fences exist, else 0.
- `leafBytes` charges `prefix_len` once (plus a length byte or two) and
  `leafCellSize(key.len - prefix_len, n_tids)` per cell.
- A search compares the search key with the prefix once, then with the remainders.
- `buildLeaf` receives the fences before the cells, so the prefix is known up front. A
  split gives each half new fences, so each half may get a *longer* prefix than the
  original page: that is why a rebuilt page must be re-encoded, not copied.

Why fences are needed: every key on the page lies between the fences, so it starts with
their common prefix. Without fences the only safe prefix is the common prefix of the keys
that are on the page right now, and the next insert may break it, forcing a rewrite of the
page. With fences the prefix is fixed until the page splits.

Pages that cannot benefit: the leftmost and the rightmost page (one fence is infinite), and
pages whose fences differ in the first byte. Note also that a truncated high fence makes the
shared prefix *shorter* than the keys' true common prefix can be: with low `user/000413/o`
and high `user/0005`, the prefix is `user/000`, although all keys on the page might share
`user/0004`. Truncation and prefix compression pull in opposite directions on the fences.

A static estimate for workload C (truncation on), computed by a throwaway change to the
Rust program that sums `prefix_len * (cells - 1)` over the leaves of the finished tree:
232 of the 234 leaves have fences with a common prefix, 9.0 bytes on average, and the
saving is 176,113 of 692,882 used bytes, about a quarter. A real implementation would do
better than the estimate, because smaller cells also mean fewer splits.
