# Chapter 27: solutions

Every number below was produced by the chapter's code. Where a number comes
from a scratch run that is not part of `expected_output.txt`, that is said.
All of them are block counts under the chapter's counting model, with its
limits: nothing is cached, every index block is charged, there is no
write-ahead log, and an LSM write is not on the device until the next flush
while a B+tree write is (README, "The counting model, and what it leaves
out"). Ratios are rounded to two decimals.

## 1. Four lookups after the trace

State after the trace (section 2 of the output): the B+tree has height 3; the
LSM-tree has `14` in the memtable, nothing in level 0, and one level-1 run
`(1 3 5 6 7 10 11 12 13 17 20 25 30)` whose key range is 1 to 30.

| | B+tree | LSM-tree | why (LSM) |
|---|---|---|---|
| `get 3` | 3 | 3 | not in the memtable; level 1 covers 3: root index block, index block, data block, found |
| `get 14` | 3 | 0 | found in the memtable |
| `get 30` | 3 | 3 | level 1 covers 30: two index blocks and the last data block, found |
| `get 31` | 3 | 0 | not in the memtable; 31 is above the run's largest key, so the run is skipped |

The B+tree always reads one block per level, hit or miss. The level-1 run has
5 data blocks, so its index has two levels (2 blocks, then a root): a probe
costs as much as the B+tree's whole path. These four results were checked by
running the visualization's model (`viz/local.js`), which the page's
self-tests tie to the programs' output, after the trace.

## 2. Index blocks cached

The "data blocks per get" row is what remains; divide the LSM column by the
B+tree column.

| Workload | B+tree | LSM-tree | LSM / B+tree, index cached | LSM / B+tree, nothing cached |
|---|---|---|---|---|
| insert-heavy | 1.00 | 3.51 | 3.5 | 9.42 / 3.81 = 2.5 |
| read-heavy | 1.00 | 3.89 | 3.9 | 10.96 / 4.00 = 2.7 |
| update-heavy | 1.00 | 3.04 | 3.0 | 7.52 / 4.00 = 1.9 |

The B+tree always ends at exactly one data block: its leaf. The LSM-tree reads
one data block per run it probes. So a cache of all index blocks helps both,
and it helps the B+tree more: the ratio between the two grows. How much RAM
such a cache needs was not measured.

## 3. A perfect filter

Read-heavy workload: 9588 gets, 37328 runs probed, 32452 of them without
finding the key. A probe costs the run's index height plus one data block, so
the saving cannot be read off the probe counts alone.

- Now: 10.96 blocks per get (the printed value; 105045 blocks).
- Scratch run (not in `expected_output.txt`): the same workload with `probe`
  changed to charge nothing when the key is not in the run. 16974 blocks
  remain, 12098 index and 4876 data: 1.77 blocks per get.

That is 4876 useful probes for 9588 gets, about half a probe per get, because
roughly half of the lookups in this workload ask for keys that do not exist
and would then cost nothing.

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
| blocks written | 13826 | 5879 |
| blocks in use at the end | 1517 | 768 |
| data blocks if packed (10800 / 15) | 720 | 720 |
| space amplification at the end | 2.11 | 1.07 |

**B+tree.** Every insert goes into the rightmost leaf. When it overflows, the
split leaves the lower half behind and nothing is ever added to it again, so
every leaf except the last stays half full: about twice the packed size.
Chapter 14 shows the fix (split at the right edge, or bulk loading).

**LSM-tree.** Its write amplification hardly improves: 5879 * 15 / 10800 =
8.17 slots per entry, against 8.39 for random keys. This LSM-tree merges whole
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
| 1 | 4 | 11.22 | 8.05 | 8.78 |
| 2 | 4 | 10.41 | 8.06 | 8.84 |
| 4 | 3 | 8.39 | 9.42 | 9.97 |
| 8 | 3 | 7.56 | 11.92 | 12.98 |

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
