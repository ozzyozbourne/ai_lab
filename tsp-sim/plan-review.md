# Plan review: findings and what was done

One review round. The reviewer was an independent agent that saw only `plan.md`
and `research/dossier.md`. It returned 24 numbered findings. Every finding was
accepted, in full or in part; none was rejected outright. Section numbers refer
to the revised `plan.md`.

| # | Severity | Finding | Decision | Change |
|---|---|---|---|---|
| 1 | Blocker | A node with the same tensor as both operands (`mul(x, x)`) made a single-operation tile fail its own check, and a fused `mul(r, r)` contradicted "the second operand is parked". | Accepted | Uses are counted per operand slot, so a tensor used twice is never fused. An operand used twice is read once and both operand fields name the same streams (3.2, 3.5, 4.1, 4.4). Tests added (5.2, 5.3). |
| 2 | Blocker | Two `matvec`s on one MXM plane fused into one tile could never be placed. | Accepted | A `matvec` always starts a tile, so a tile holds at most one (4.1). All remaining constraints are lower bounds on the start time, which the termination argument now states (4.5). |
| 3 | Blocker | Queue timing (`Nop` gap, `Repeat`, what a data instruction occupies) was undefined between the queue model and the emitter. | Accepted | A table of cycles occupied per queue element and a worked example (2.6); `Repeat` bounds added to `check_program` (3.7). |
| 4 | Major | The validator's latency check could not be computed from the trace. | Accepted | Dispatch records gain `did` and `kind`; emissions and memory writes carry `did`; `values[*].cycle` is defined as the emission cycle (3.4, 5.1). |
| 5 | Major | Latency keys undefined; `requant` had no ledger latency; two latency tables. | Accepted | `ChipConfig.latency` is the only table and its keys are listed (3.1). Ledger T8 now covers `requant`, and `mask` is removed from it. |
| 6 | Major | Placement of tensors that are both matrix rows and inputs or computed values; unclear M3 outputs. | Accepted | Matrix rows are placed first by the matrix rule, whatever else they are (4.2). M3 outputs are `logits`, `k16`, `v` (6). |
| 7 | Major | "Unspecified but finite" padding lanes were not enforced and could turn into infinities or NaN. | Accepted, with a different fix | Instead of a column count on `Abc`, every result-producing instruction carries a length and zeroes lanes above it, so all values are zero-padded everywhere (2.3, ledger B19). |
| 8 | Major | The M3 tolerance was fragile because `fp16` casts amplify last-bit differences, and the accumulation order was unspecified. | Accepted | The MXM sum is defined exactly: `float64` products in ascending lane order, one rounding (2.5, ledger B7). M3 is checked bit-for-bit against `evaluate` and with a deliberately loose tolerance against an independent NumPy reference (5.3). |
| 9 | Major | `asm.dispatch_times` needed the configuration. | Accepted | Signature is `dispatch_times(queue, config)` (3.7). |
| 10 | Major | "Sorted" JSON would lose the canonical queue order. | Accepted | Queues are serialised as an ordered list; code iterates `config.units()`; encodings are defined in `program.py` (3.3). |
| 11 | Minor | Some ledger rows were marked SOURCED without support in the dossier text. | Accepted | B14, B22, G11 and G14 re-marked; the supporting quotes for B2, B14 and B22 were added to dossier sections 1.3, 1.5 and 1.6. |
| 12 | Minor | Unledgered behaviours: VXM data types, two results from one unit on a cycle, zero padding, the notifier, no epsilon or max-subtraction. | Accepted | VXM arithmetic restricted to 32-bit operands (2.5, B11); two results per cycle allowed on different registers (B18); padding in B22; notifier in B14; M3 adds an epsilon and states the missing max-subtraction as a limit (6). |
| 13 | Minor | T7 and T11 were not wired into the simulator. | Accepted | Commit happens at the end of cycle `t + latency - 1` (2.3). The validator does not check these; the hardware tests do (5.1). |
| 14 | Minor | Two validator checks could not fail. | Partly accepted | Kept as cheap format checks and labelled as such; schedule-against-trace checks that can fail were added (5.1). |
| 15 | Minor | The negative test could pass for the wrong reason because tags repeat and `expect` was optional. | Accepted | Compiler tags are unique per emission (`tensor@tile#plane`) and `expect` is always set (3.2). The schedule's `t_emit` is defined (4.6). |
| 16 | Minor | The traceability scan covered the HTML template and exempted the literal 2. | Accepted | Only `.py` files are scanned and only 0, 1 and -1 are exempt (5.3). |
| 17 | Minor | Colour per tile had no data source. | Accepted | Schedule entries carry `tile` (4.6, 7). |
| 18 | Minor | `broadcast` binding undefined after a fused VXM operation. | Accepted | Three ordered rules (4.3). |
| 19 | Minor | `broadcast` cannot be expressed on the 320-lane configuration; M1 lacked a size parameter. | Accepted | `CompileError` when tiles > 1 (4.3); `m1.build` takes sizes (6). |
| 20 | Minor | Self-check gaps: other units, re-placement after a restart, "at or after". | Accepted | Operations in a tile fire at strictly increasing times, so only MEM reads can clash (4.1); placement is recomputed on restart (4.2); wording fixed (4.5). |
| 21 | Minor | Weight rows were dealt from the slice farthest from the MXM; no fallback for window choice. | Partly accepted | Rows now start nearest the MXM, and every window offset is tried (4.2). There is still no fallback beyond that: an impossible placement is a `CompileError`, which is acceptable for a toy compiler. |
| 22 | Minor | Numeric gaps: int8 overflow, `fp32 -> int32`, `fp16` arithmetic, `Permute` direction, byte order. | Accepted | Widening defined; `fp32 -> int32` removed; `fp16` arithmetic not offered; `out[i] = in[map[i]]`; little-endian helpers (2.5, 3.2). |
| 23 | Minor | The digest did not cover data; the hash-seed test covered only the compiler. | Accepted | The trace records the final output bytes and the digest's coverage is stated precisely (3.4); the hash-seed test covers compile and simulate (5.3). |
| 24 | Minor | Contract gaps: error classes, `reference` signature, tolerance for random graphs, `record_cells`, cell order, hashing of `ChipConfig`, Chromium. | Accepted | Error classes live in the lead-owned `tsp/errors.py`; `reference(seed)` regenerates its own constants (8); random graphs are bit-exact against `evaluate` (5.3); cell order and `record_cells` defined (3.4); the Chromium test is skipped if Playwright is missing (5.2). `ChipConfig` is never used as a dict key, so its unhashable field is left as is. |
