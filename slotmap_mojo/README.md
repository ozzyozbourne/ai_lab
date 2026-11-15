# Mojo SlotMap vs Rust `slotmap`

A Mojo implementation of a slot map (generational arena with stable, versioned
keys), hill-climbed against Rust's [`slotmap::SlotMap`](https://github.com/orlp/slotmap)
until it was at least as fast.

- `slotmap.mojo`: the final implementation (`SlotMap[V]`, `Key`).
- `test_slotmap.mojo`: randomized model test against `Dict`, plus `String` and 1-byte values.
- `bench.mojo` and `rust_bench/`: the same 12 workloads in both languages, with identical PRNG, operation order and checksums.
- `compare.py`: builds a variant, runs it paired with the Rust reference, prints and logs the score.
- `ab.py`: interleaved A/B timing of several benchmark binaries.
- `variants/`: every step of the hill climb, `v0_port` to `v16_scaled`.
- `results/`: per-variant tables and `log.tsv`.
- `hill_climb.html`: illustrated walk through every step, with Rust and Mojo assembly side by side. Open it in a browser.

Toolchains used: Mojo 1.2.0, Rust 1.100.0 with `slotmap` 1.1.1, on a 4-vCPU
Intel Emerald Rapids VM (Linux 6.18, transparent huge pages in `madvise` mode).

## Result

Mojo cycles / Rust cycles per operation (below 1.00 means Mojo is faster),
values are `u64`, 9 paired rounds:

| Workload | n=1,000 | n=100,000 | n=2,000,000 |
|---|---|---|---|
| `insert_grow` | 3.46 / 3.96 = **0.88** | 2.61 / 3.55 = **0.73** | 11.56 / 23.50 = **0.53** |
| `insert_reserved` | 2.60 / 3.76 = **0.68** | 2.56 / 3.77 = **0.68** | 9.70 / 10.73 = **1.02** |
| `get_seq` | 1.60 / 1.72 = **0.93** | 2.71 / 2.43 = **1.10** | 6.65 / 7.80 = **0.83** |
| `get_rand` | 1.61 / 1.73 = **0.93** | 5.09 / 5.89 = **0.92** | 17.43 / 28.62 = **0.67** |
| `get_mixed_rand` | 14.87 / 14.10 = **1.06** | 23.93 / 21.86 = **1.09** | 30.71 / 43.68 = **0.76** |
| `iter_values_full` | 1.11 / 1.59 = **0.69** | 1.49 / 1.94 = **0.69** | 3.20 / 6.84 = **0.50** |
| `iter_values_half` | 2.87 / 12.68 = **0.22** | 3.22 / 14.31 = **0.23** | 5.77 / 16.86 = **0.37** |
| `iter_kv_half` | 3.45 / 12.24 = **0.28** | 3.71 / 13.59 = **0.28** | 6.25 / 16.07 = **0.40** |
| `remove_seq` | 2.54 / 3.01 = **0.82** | 3.34 / 3.22 = **1.02** | 7.01 / 8.58 = **0.89** |
| `remove_rand` | 3.02 / 3.09 = **0.98** | 6.28 / 8.24 = **0.76** | 21.76 / 34.82 = **0.63** |
| `reinsert_rand` | 2.43 / 6.28 = **0.38** | 4.58 / 32.46 = **0.17** | 13.62 / 464.44 = **0.03** |
| `churn` | 8.37 / 12.23 = **0.69** | 26.20 / 39.33 = **0.70** | 107.29 / 189.62 = **0.54** |

Geometric mean 0.57; Mojo is ahead or level on 31 of 36 measurements and
within 10% on the other five (mixed hit/miss lookups at the two smaller sizes,
sequential lookups and removes at 100,000, reserved inserts at 2,000,000).

Removal rows time `pop(key) raises` (the `Dict.pop` idiom). With
`remove(key) -> Optional[V]` the remove rows are 1.00 to 1.10 and churn is
0.62 to 0.73 (`results/final_v16_optional_remove.txt`).

## What makes it faster

1. Free slots are a LIFO stack of handles, not a list threaded through the
   vacant slots, so refilling scattered holes is not a pointer chase.
2. That stack is stored in the slots' own padding bytes (no extra memory for
   8-byte-aligned values, no second allocation).
3. No element counter; `len` is derived from the slot count and stack height.
4. Keys hold a pre-scaled slot handle, so a slot address is one scaled-index
   addressing mode.
5. Iteration walks runs of occupied slots found through a 64-slot occupancy
   mask, and skips scanning entirely when the map has no holes.
6. A custom allocator: malloc/realloc below 8 MiB; above that, one mmap region
   reserved at 16x (grows in place) and backed by transparent huge pages.

## Running

```bash
mojo run -I . test_slotmap.mojo
```

```bash
python3 compare.py final --rounds 9
```

```bash
python3 compare.py v7_lean --only remove,churn --rounds 3
```

`compare.py` options: `--only a,b` (workload substrings), `--rounds N`,
`--optional-remove` (time `remove()` instead of `pop()`), `--unroll-lookups`
(hand-unroll the Mojo lookup driver loop 4x).

## Measurement notes

- Times are CPU cycles per operation: each benchmark brackets its timed
  batches with a fixed calibration loop and drops batches where the clock
  speed changed, because this VM's core frequency moves between levels about
  27% apart.
- Rust and Mojo run back to back per workload; the ratio is the median over
  rounds.
- Random seeds change every repetition so the branch predictor cannot
  memorize a pattern across repetitions.
- `results/log.tsv` rows before `v7_lean` were scored in raw nanoseconds with
  an earlier, noisier protocol; rows before `v15_adaptive` used a fixed seed.
