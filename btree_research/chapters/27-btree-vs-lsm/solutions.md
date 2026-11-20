# Chapter 27: solutions

Every number below was produced by the chapter's code. Where a number comes
from a scratch run that is not part of `expected_output.txt`, that is said.

## 1. Four lookups after the trace

State after the trace (section 2 of the output): the B+tree has height 3; the
LSM-tree has `14` in the memtable, nothing in level 0, and one level-1 run
`(1 3 5 6 7 10 11 12 13 17 20 25 30)` whose key range is 1 to 30.

| | B+tree | LSM-tree | why (LSM) |
|---|---|---|---|
| `get 3` | 3 | 2 | not in the memtable; level 1 covers 3: index block + data block, found |
| `get 14` | 3 | 0 | found in the memtable |
| `get 30` | 3 | 2 | level 1 covers 30: index block + last data block, found |
| `get 31` | 3 | 0 | not in the memtable; 31 is above the run's largest key, so the run is skipped |

The B+tree always reads one block per level, hit or miss. These four results
were checked by running the visualization's model (`viz/local.js`), which the
page's self-tests tie to the programs' output, after the trace.

## 2. Index blocks cached

Subtract the "of which index blocks" row from the row above it.

| Workload | B+tree | LSM-tree |
|---|---|---|
| insert-heavy | 3.80 - 2.80 = 1.00 | 7.01 - 3.50 = 3.51 |
| read-heavy | 4.00 - 3.00 = 1.00 | 7.78 - 3.89 = 3.89 |
| update-heavy | 4.00 - 3.00 = 1.00 | 6.08 - 3.04 = 3.04 |

The B+tree always ends at exactly one data block: its leaf. The LSM-tree reads
one data block per run it probes, so caching the index halves its cost and no
more. (The printed ratios are truncated to two decimals, so the last digit of
a difference can be off by one.)

## 3. A perfect filter

Read-heavy workload: 9588 gets, 37328 runs probed, 32452 of them without
finding the key. A probe costs 2 blocks.

- Now: 37328 * 2 / 9588 = 7.78 blocks per get (the printed value).
- With a perfect filter only the 37328 - 32452 = 4876 useful probes remain:
  4876 * 2 / 9588 = 1.01 blocks per get, truncated.

That is about half a probe per get, because roughly half of the lookups in
this workload ask for keys that do not exist and would then cost nothing.

A real bloom filter is not perfect. It never says "absent" for a key that is
present, but it sometimes says "maybe" for an absent key, so some wasted
probes remain. It also needs memory per key and must be built during every
flush and compaction. How many probes remain depends on the bits spent per
key; this was not measured here, since the chapter's code has no filter.

## 4. Ascending keys

Scratch run (not in `expected_output.txt`): 10800 puts with keys 0, 1, 2, ...
into a B+tree of order 16 and into the benchmark LSM configuration.

| | B+tree | LSM-tree |
|---|---|---|
| blocks written | 13826 | 5825 |
| blocks in use at the end | 1517 | 763 |
| blocks if packed (10800 / 15) | 720 | 720 |
| space amplification at the end | 2.10 | 1.05 |

**B+tree.** Every insert goes into the rightmost leaf. When it overflows, the
split leaves the lower half behind and nothing is ever added to it again, so
every leaf except the last stays half full: about twice the packed size.
Chapter 14 shows the fix (split at the right edge, or bulk loading).

**LSM-tree.** Its write amplification does not improve: 5825 * 15 / 10800 =
8.09 slots per entry, against 8.31 for random keys. This LSM-tree merges whole
levels, so it rewrites level n + 1 even when the incoming keys are all larger
than everything in it. An engine that compacts table by table can notice that
nothing overlaps and move the table by changing metadata only; that is
TigerBeetle's move-table optimisation
(`tigerbeetle/docs/internals/lsm.md:111-120`). It is not implemented here, so
its effect was not measured.

## 5. Level-0 runs

Scratch run (not in `expected_output.txt`): the insert-heavy workload with
only `l0_runs` changed. All four runs agreed with the oracle.

| `l0_runs` | levels | write amplification | blocks per get | blocks per scan |
|---|---|---|---|---|
| 1 | 4 | 11.09 | 5.51 | 6.27 |
| 2 | 4 | 10.29 | 5.58 | 6.35 |
| 4 | 3 | 8.31 | 7.01 | 7.59 |
| 8 | 3 | 7.50 | 9.78 | 10.86 |

More runs in level 0 means level 1 is rewritten less often: with `l0_runs = 1`
every flush is merged into level 1 at once, with 8 only every eighth flush. So
write amplification falls. But the runs of level 0 overlap, and a lookup has
to probe each one whose key range covers the key (with random keys, nearly all
of them). So reads rise. In this implementation `l0_runs` also multiplies
every level's limit, which is why the number of levels drops from 4 to 3.

Letting several overlapping runs wait before merging is the idea behind
"tiered" compaction; keeping one run per level is "levelled". This parameter
slides level 0 from one towards the other. That naming is textbook; the
numbers are from this chapter's code only.
