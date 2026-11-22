# Independent verification of sim_grok_1

Verified on 2026-11-14 against the working tree at commit `713c55c` (clean), and re-verified after fixes at commit `8841250` (see the section "Re-verification after fixes" at the end). Environment: Python 3.13, NumPy as installed, headless Chromium via Python Playwright.
The verifier did not build any part of the project and did not change any project file apart from creating this one.

Every verdict below rests on scripts written for this verification. The project's tests, `tsp/validate.py`, `tsp/reference.py` and the `reference()` functions in `tsp/models/` were not used as evidence. They were run only as extra information, and where they appear below that is stated.
The project code was used only to build graphs (`tsp.models.m*.build`), compile, simulate, and read the data formats. The scripts are in
`/tmp/claude-0/-home-user-ai-lab/c8af10d4-242d-50e2-9b7d-29e982e88ffc/scratchpad/verify/` (listed at the end).

## Summary

| Check | Sub-check | Original (713c55c) | Re-verified (8841250) | Evidence (original run; see "Re-verification after fixes" for the rerun) |
|---|---|---|---|---|
| 1 Numerical | M1 int, exact | PASS | PASS | 5 seeds (0,1,2,3,42): bit-exact against a scalar Python reference; 1–6 of 8 outputs zero per seed |
| 1 Numerical | M2 int, exact | PASS | PASS | 5 seeds bit-exact; hidden layer h has 6–10 zeros of 16, 0–2 saturated; all 8 outputs distinct |
| 1 Numerical | M3 fp32/fp16 | PASS | PASS | 5 seeds **bit-exact** (max abs and rel error 0) against my fp32 + fp16-cast reference; against fp64 with no fp16 casts: max abs 1.7e-3, max rel 7.6e-2 (on an element of size 1e-2) |
| 1 Numerical | non-trivial, padding | PASS | PASS | no output is all zero, all values finite, softmax sums 0.99991–1.00012; output padding lanes all zero |
| 2 Determinism | separate processes, PYTHONHASHSEED 0/0/1/2/random/12345 | PASS | PASS | `Program.to_json()`, full trace JSON and `n_cycles` byte-identical over 6 processes for each milestone |
| 2 Determinism | code inspection | PASS | PASS | no set iteration, hashing, randomness, time or `id()` affects any output; `set` is used only for membership tests (`timeline.py:46`, `validate.py:192`) |
| 3a | lane exclusivity / no early overwrite | PASS | PASS | my reconstruction of all cells from emissions equals `trace.cells` list for list (214 / 533 / 4951 cells); every one of 25 / 55 / 452 reads finds its own vid in the register |
| 3b | unit booking, queue re-derivation | PASS | PASS | at most one dispatch per (unit, cycle); my plan-2.6 expansion of every queue gives exactly the trace's (cycle, kind, text) for 21 / 48 / 401 dispatches |
| 3c | exact arrival, latency, motion | PASS | PASS | every read satisfies t = t_e + \|x − x_e\| on the correct side; every emission lands exactly at the latency parsed from the ledger table (not from `params.py`); motion is 1 position per cycle with values dropped at the edge |
| 3d | memory | PASS | PASS | 13 / 34 / 278 MEM Reads all read a preloaded constant whose bytes are that constant's plane, the poked input named by the tag, or a word committed ≥1 cycle before; no address written twice; outputs read from words written with the output tensor's tag |
| 3 | instruction semantics vs graph | PASS | PASS | each Abc, Vxm and Distribute matches its graph node (op, n, dtype, operands); for every Abc, rows 0..n_rows−1 hold the matrix's rows (latest Iw); every op tensor is produced exactly once |
| 3 | mutation testing | PARTIAL | PASS (opcode limit ACCEPTED) | all 1,930 timing, stream and whole-instruction-swap mutants are caught by the simulator, and also by `validate.py` once the simulator's tag checks are turned off. **249 of 2,226 mutants (wrong MEM address, changed VXM opcode) pass both the simulator and `validate.py`; 21 of those still give a bit-exact correct answer.** See V1 |
| 4 | numeric literals | PASS (with notes) | PASS | 0 unannotated literals in 32 .py files; 32 `not-a-parameter` notes read: 4 are the chip lane count in disguise (V3), 2 encode an unledgered position rule (V4) |
| 4 | ledger IDs and values | PASS | PASS | all 51 IDs cited in the code exist; every `params.py` value equals its ledger Sim value, or for 20/44/2, 65535 and −128/127 the sourced value or a value derived from the row |
| 4 | SOURCED rows cited | PASS | PASS | all 27 SOURCED or partly SOURCED rows carry a source tag or a derivation; 6 of 7 quoted phrases were found verbatim in research/01–04; the 7th (B8) is an elided form of a quote that is there |
| 4 | assumed shown as fact | PASS (minor) | PASS | README, HTML note and comments mark latencies, geometry and so on as assumed. Minor: the docstring `params.isca2020` "Sourced geometry" overstates (V4), and README says latencies are checked "against the ledger" (V2) |
| 4 | behaviour rows T3 T4 B1 B2 B4 B10 B12 B18 B19 B21 | PASS | PASS | from traces, from a hand-written program (overwrite, two results from one ALU on one cycle, Repeat, collision) and by intercepting 532 emitted planes (B19); see section 4 |
| 5 | renders, no errors | PASS | PASS | 3 pages × (1400×900 light, 1400×900 dark with zoom clicks, 390-px phone): 0 console errors, 0 page errors, no horizontal page scroll on the phone |
| 5 | embedded data = trace | PASS | PASS | `DATA.trace` deep-equals the trace JSON; the embedded digest equals SHA-256 of the trace file |
| 5 | cells one-to-one | PASS | PASS | dispatch cells equal trace dispatches by (unit, cycle, label) (21/48/401), each in its unit's row and the right column. Lane cells equal occupied (lane, cycle) pairs (167/388/2951), with exact label and faded state |
| 5 | space-time view | PASS | PASS | for 5 sampled cycles per milestone, the (dir, stream, pos, tag) of every value and the dispatching units match `trace.cells` exactly, each in the column of its position |
| 5 | committed = fresh | PASS | PASS | `timelines/*` (html, json, asm) byte-identical to `python -m tsp.run all --out out1` |
| 5 | screenshots | PASS (cosmetic notes) | PASS (V6 cosmetic, open) | latencies clearly labelled as assumed; nothing overlaps; labels truncated at default zoom (V6) |
| 6 | deliverables and README | PASS (minor) | PASS (V5 fixed) | all deliverables present; README cycle counts (68/96/465), the README example ([20 0]) and the 320×320 isca2020 run (bit-exact, my validator clean) all hold. Dossier table formatting defect (V5) |

## 1. Numerical correctness

**Method.** `check1_numeric.py` replays the RNG draws from each model file (they were read, not imported) and runs the forward pass in plain NumPy or Python.

- **M1 and M2:** pure-Python integer loops. Requantise is written as `min(127, max(-128, v // 256))`.
- **M3:** written from the mathematics, in two versions:
  - (a) fp32 VXM arithmetic, with every MXM operand rounded to fp16 and each MXM sum taken exactly in float64 and rounded once to fp32 (ledger B6/B7).
  - (b) all float64 with no fp16 rounding of activations; the weights keep their stored fp16 values.

The simulator's outputs are decoded by my own code from `trace.outputs` hex, not with `sim.peek`. I also confirmed that my regenerated M3 inputs equal what the model pokes. Seeds: 0, 1, 2, 3, 42.

**Tolerance for M3:** |sim − ref| ≤ 1e-3·|ref| + 1e-3. It is chosen as about 2 fp16 ulps relative, because a last-bit difference in an fp32 sum can flip one later fp16 rounding (relative 4.9e-4). In the event it was not needed: all three outputs (`logits`, `k16`, `v`) were **bit-identical** to reference (a) for all 5 seeds.

**Evidence.**

| | seed 0 | 1 | 2 | 3 | 42 |
|---|---|---|---|---|---|
| M1 exact / zeros of 8 | yes / 4 | yes / 6 | yes / 3 | yes / 4 | yes / 7 |
| M2 exact / h zeros, saturated | yes / 8, 2 | yes / 10, 0 | yes / 6, 1 | yes / 10, 0 | yes / 9, 0 |
| M3 vs (a) max abs err | 0 | 0 | 0 | 0 | 0 |
| M3 logits vs (b) max abs / max rel | 1.08e-3 / 4.0e-2 | 4.3e-4 / 3.9e-3 | 1.73e-3 / 3.5e-3 | 1.04e-3 / 2.8e-3 | 3.6e-4 / 8.0e-3 |
| M3 k16 vs (b) max rel | 7.7e-4 | 7.6e-2 | 4.9e-4 | 2.2e-3 | 2.0e-3 |

The large relative errors against (b) occur on elements near zero; the absolute error is always below 2e-3.

M3 outputs are non-trivial: |logits| up to 2.3–3.9 with no zeros; exp(scores) lies in [0.27, 3.5]. Padding lanes of every output are zero.

## 2. Determinism

**Method.**
- `check2_determinism.py` runs `det_dump.py` in 6 separate Python processes with PYTHONHASHSEED = 0, 0, 1, 2, random and 12345.
- For each milestone, each process writes `Program.to_json()`, `Trace.to_json()` and `n_cycles`, and the files are compared byte for byte.
- I grepped `tsp/` for `set`/`frozenset`, `hash`, `id(`, `random`, `time`, environment access and dict-view iteration, and read the compiler's scheduler and emitter.

**Evidence.** All 9 file groups are identical: M1 program 6,871 B, trace 12,329 B; M2 14,586 / 28,005 B; M3 107,446 / 249,040 B. The committed `timelines/*_trace.json` equal the fresh traces.

The only `set` uses are membership tests. Every sort in the compiler has a total key. The `Simulator` orders emissions by `(did, s)` and commits by `did`.

One residual platform dependence is documented in plan 2.5: `np.exp` and `np.tanh` may differ between NumPy builds. It was not tested across machines.

## 3. Schedule validity

**Method.** `myvalidate.py` is written from plan sections 2.1, 2.3, 2.6 and 3.4 without reference to `tsp/validate.py`, and `check3_schedule.py` runs it on M1–M3 for seeds 0, 1 and 2. Latencies and the barrier are parsed from the ledger table in `research/dossier.md`. Unit positions come from the plan 2.1 table.

For each run it:

- (b) expands every queue (Sync/Notify, `Nop n`, `Repeat n,d`) into dispatch cycles and matches each trace dispatch's cycle, kind and text, plus its position, against the instruction it came from;
- (c) checks every emission: latency equals the ledger value for its kind; it is at the producer's position, on the instruction's result streams, with the right plane tag; and each producing dispatch has exactly as many emissions as its result has planes;
- (a, c) rebuilds every register on every cycle from the emissions alone (shift by one, drop at the edge, emission replaces), then requires the rebuild to equal `trace.cells` and every emission's `overwrote` field;
- checks every read: it is the instruction's operand streams, in operand order, at the unit's position; the register really holds the read vid; the arrival rule holds; and the tag equals the instruction's `expect`;
- (d) for every MEM Read, finds where the word came from:
  - a constant: the word must equal the zero-padded plane j of the graph constant named by the tag;
  - an input: it must be the input location named by the tag;
  - a written word: it must have been committed at least one cycle earlier with the same tensor tag.
  It also checks that write commits are at dispatch + T7 − 1, that no address is written twice, that inputs and constants are never written, and that output locations hold the output tensor's planes;
- checks semantics against the graph: every Abc, Vxm and Distribute has the op, length, dtypes, operands and requant shift of its graph node, and the rows installed on the plane are the matrix's rows; B10 directions; B21 end cycle.

**Evidence.** 0 errors on all 9 runs.

| | dispatches | emissions | cells | reads | MEM reads (const / input / written) | writes |
|---|---|---|---|---|---|---|
| M1 | 21 | 25 | 214 | 25 | 13 (12/1/0) | 4 |
| M2 | 48 | 55 | 533 | 55 | 34 (32/1/1) | 5 |
| M3 | 401 | 452 | 4951 | 452 | 278 (178/34/66) | 50 |

No milestone overwrites a value: there are 0 emissions with `overwrote` set, so the overwrite path is exercised only by the hand-written program in section 4. Every emitted value is read at least once.

### Mutation testing

`check3_mutation.py` generates these mutants of each compiled program:

- `insert_nop`: Nop(1) before an instruction, which shifts the rest of the queue;
- `delay_one` and `advance_one`: move a single instruction by one cycle;
- `out_stream` and `operand_stream`: move a result or operand to the next aligned stream;
- `swap_reads`: swap two Read instructions in one queue;
- `swap_read_addrs` and `cross_swap_read_addrs`: swap only the addresses of two Reads, in one queue or across two queues;
- `write_addr`: point a Write at an address already in use;
- `vxm_op`: change add to sub and back.

Each mutant is run through the simulator, then `tsp/validate.py`, then my validator, then compared bit-exactly with my references. `check3_mutation_noexpect.py` repeats the run with every `expect` field cleared, so the simulator's tag checks cannot fire and `validate.py` has to work on its own.

| | mutants | simulator raised | passed sim + validate.py, output wrong | passed sim + validate.py, output **right** |
|---|---|---|---|---|
| M1 | 93 | 88 | 5 | 0 |
| M2 | 212 | 191 | 18 | 3 |
| M3 | 1921 | 1698 | 205 | 18 |

- Every timing, stream, whole-swap and write-address mutant was caught by the simulator: 1,433 `EmptyOperandError` and 265 `OperandTagError` in M3.
- With tag checks off, every such mutant that still ran to completion was flagged by `validate.py`. There were no misses in that class; `validate.py` works as a timing checker.
- All 249 mutants that passed both are wrong-address Reads or opcode changes. `run.py`'s numeric comparison catches 228 of them; **21 produce a correct answer by accident and are invisible to all of the project's checking**. Examples: M2 swapping the addresses of rows W1[0] and W1[8] (both multiply h = 0); M3 swapping byte-plane 0 of `x` and `eps`.
- My validator flagged all 249, through its memory-content and graph-semantics checks. See V1.

## 4. Traceability

**Literals.** `check4_traceability.py` walks the AST of all 32 .py files under `tsp/`, folding unary minus, and reads comments with `tokenize`.

- Literals other than 0/1/−1: all in `params.py` with `# ledger: ID`, or annotated `# not-a-parameter:`. No literal is unannotated.
- I read all 32 annotations and judge 26 genuinely not parameters: model sizes, RNG scales, M2 SHIFT, EPS, the int32 width in `reference.py`, test tolerances, ns conversion, "a pair has 2 entries", 2-D, and the shift range 0..31.
- **Not genuine:** `lanes = 16` (`graph.py:50`) and `LANES = 16` (`m1.py:19`, `m2.py:21`, `m3.py:64`) are the toy chip's lane count G1×G2 under a "model size" label (V3). The `+ 2` / `- 2` at `params.py:120,152` encode the position layout (V4).

**IDs and values.**
- All 51 IDs cited in code exist in the ledger. Rows never cited in code: B3, B12, B15, B18, G6, T5, T18 (icu.py names T18 without the `ledger:` prefix).
- Every `params.py` value equals the Sim value of its row. The exceptions are explained by the row: TILES/MEM/MXM ISCA2020 = 20/44/2 is the sourced value given in the row's reasoning; NOP_MAX 65535 is 2^16−1 from "16 bits"; INT8 ±128/127 is "saturate to int8"; NON_MEM_POSITIONS 5 gives 21 = 2·8 + 5 for G8.

**SOURCED rows.** `check4_sourced.py` finds a source tag or an explicit derivation in all 27 SOURCED or partly SOURCED rows. Six of the seven quoted phrases occur verbatim in research/01–04. B8's quote is an elision of the sentence on report 01 line 201.

**Behaviour rows.** `check4_behaviour.py` checks these from the milestone traces, from in-process interception of every emitted plane (monkeypatch only, no file edits), and from a hand-written program.

| Row | What the code does | Verdict |
|---|---|---|
| T3 | emission placed at the producer's position after the shift, replacing the arriving value. Hand program: `second#0` overwrote vid 20 (`first#0`), `first#0`'s last cell is x10 at cycle 54, and the downstream Write stored `second`'s bytes | PASS |
| T4 | operands are sampled on the dispatch cycle: every read's (cycle, register) holds the vid read | PASS |
| B1 | 448 of 452 M3 values leave at an edge before the run ends; the rebuild with edge drop equals `cells` | PASS |
| B2 | reads never remove a value: the rebuild ignores reads and still matches | PASS |
| B4 | one queue per MEM slice, at most one dispatch per (unit, cycle) | PASS |
| B10 | MXM_W reads W and emits E; MXM_E reads E and emits W, in every trace | PASS |
| B12 | 4 / 8 / 60 same-cycle VXM→VXM reads; in milestones always on the same ALU. Cross-ALU reading at x10 was shown in the hand program | PASS |
| B18 | 9 (M2) and 110 (M3) back-to-back dispatches whose first has latency > 1. Hand program: VXM_A1 `mul` at 41 and `add` at 42 both emit on cycle 43 into different registers, with correct results [49, 9, 1410065408] and [14, −6, 200000] | PASS |
| B19 | 532 emitted planes intercepted: 0 have a non-zero lane at or above n (row count for Abc, tensor length for Read) | PASS |
| B21 | n_cycles = max(last event + 1, end of the longest queue) in all runs (68/96/465; hand program 58). A value still in flight at the end is ignored | PASS |
| T15/B14 | only VXM_A0 starts with Notify; first data dispatch at cycle 35 | PASS |
| T18 | hand `Repeat(2,4)` gives Read at 38, 42, 46, as in plan 2.6's worked example. 3,000 random queues give 0 differences between `tsp.icu.InstructionQueue` and my expansion | PASS |

Two results due in one register on one cycle raise `StreamCollisionError` (shown with two ALUs, `check6_more.py`).

## 5. Visualisation

**Method.** `check5_viz.py` loads each freshly generated timeline in headless Chromium (Playwright, deviceScaleFactor 1) and checks:

- console and page errors;
- that the embedded `timeline-data` equals the trace JSON, and the digest equals SHA-256 of the trace file;
- every `.cell[data-kind=dispatch]` against trace dispatches by (unit, cycle, mnemonic), plus its `data-did`, its row label and its pixel column;
- every `.cell[data-kind=lane]` against my own expectation built from `trace.cells`: one cell per occupied (lane, cycle) from the first drawn column on, labelled `[count·]tag` of the first live value, and faded only when no value in it has a later reader;
- the space-time view: it clicks the ruler at 5–6 sampled cycles and compares every `.st-val` (dir, s, pos, tag) and `.st-disp` unit with the trace, including the grid column.

`check5_dark.py` adds dark mode and the zoom buttons. Screenshots are in `shots/`.

**Evidence.**
- 0 errors in all views.
- Data equal; digest equal.
- Dispatch cells 21/48/401 = trace. Lane cells 167/388/2951 = occupied lane-cycles, with labels and fading exact. All space-time samples exact.
- The barrier band hides nothing (no dispatch or cell before cycle 35).
- The header note says "Every instruction latency in this run is an assumption … (ledger entries T6 to T13)" and lists the assumed latencies.
- No horizontal page scroll at 390 px.

Screenshots show nothing overlapping or clipped. Cosmetic points are recorded in V6.

## 6. Other observations

- **Deliverables present:** `research/dossier.md` (ledger in section 7), `plan.md`, `plan-review.md`, source, `tests/` (355 tests, all passed when run with `-p no:cacheprovider`; supplementary only), three HTML timelines with traces and asm, and README.
- **README claims checked:**
  - the cycle counts;
  - the 35-cycle barrier being included;
  - the "Compile your own graph" snippet, which runs and prints `[20 0]`;
  - "one test runs M1 at 320x320": my own run on `ChipConfig.isca2020()` is bit-exact against my reference, my validator reports 0 errors, and it takes 145 cycles;
  - the simulator raising on empty or wrong-tag operands, confirmed by mutation;
  - the plan 3.4 orderings of dispatches, emissions and cells;
  - all planes of a tensor on distinct slices of one hemisphere;
  - traces containing no floats.
- `validate.py` compares latencies with `program.config.latency`, not with the ledger. I compiled M1 with read = 3 and abc = 5; `validate()` returned no errors and my ledger-based validator returned 17 (V2).

## Findings to fix

| ID | Severity | Finding |
|---|---|---|
| V1 | Medium | **Wrong-address reads and wrong opcodes are invisible to the simulator and `validate.py`.** Tags are attached by the `Read` instruction itself (`tsp/hw/simulator.py:168-170`: data from `instr.addr`, tag from `instr.tag`); memory stores no tag; `tsp/validate.py` has no memory check. Reproduction: compile M2 (seed 0) and swap the `addr` fields of `MEM_W6` queue entries 2 and 3 (`Read addr=0 tag="W1[1]@0#0"` and `Read addr=1 tag="W1[9]@1#0"`). The simulator runs, `validate()` returns `[]`, and y is wrong. Across all milestones 249 of 2,226 mutants pass both checkers; 21 even give the right answer by accident, so no project check would ever notice them. Why it matters: the claim that a timing or placement mistake turns into a failure covers streams but not memory. Only the end-to-end numeric comparison guards memory placement, and it can be fooled by zeros or low-order bytes. Fix: store the writer's or constant's tag with each MEM word and check `Read.tag` against it, and/or add a memory-provenance check to `validate.py`. |
| V2 | Low | `README.md:121` says the validator checks that "every latency matches the ledger". It checks `program.config.latency` (`tsp/validate.py:211`, `:219`). A program compiled with non-ledger latencies validates clean (`check6_more.py`: read = 3, abc = 5 gives 0 errors). Fix: compare with `params.default_latency()`, or reword the README. |
| V3 | Low | The chip lane count is hidden under "not-a-parameter: model size": `tsp/graph.py:50` (`lanes: int = 16`), `tsp/models/m1.py:19`, `m2.py:21`, `m3.py:64` (`LANES = 16`). This contradicts README.md:128-129 ("Every numeric parameter in the code lives in tsp/params.py"). Changing `LANES_PER_SUPERLANE` or `TILES_TOY` would leave the models building 16-lane graphs. Fix: derive these from `params` / `ChipConfig.toy().lanes`. |
| V4 | Low | `tsp/params.py:120` (`+ 2`) and `:152` (`- 2`) encode the rule that all MXM planes of a hemisphere share one stream-register position, with the SXM one position inside it. No ledger row states this (G8 says only "one per slice"), and it affects `isca2020()`, where two planes share x0. The `isca2020()` docstring "Sourced geometry of the ISCA 2020 chip" overstates: G8 (93 positions against a sourced reading of 45) and G14 are ASSUMED. Fix: add a ledger row or note, and reword the docstring. |
| V5 | Low (docs) | `research/dossier.md:284`: a blank line splits the Behaviour table, so rows B18–B22 have no header row and render as plain text in standard Markdown. Rows are also out of order (T18 before T17, C4 before C3). |
| V6 | Cosmetic | Timeline readability at the default 34-px zoom: `write` shows as `wri…` and lane tags as `Wx@…` (the full text is in the tooltip and at higher zoom). The space-time view auto-scrolls to the first busy column, so a dispatching unit at the far end can be off-screen; at M3 cycle 113 the `MXM_E0` Abc is listed below the grid but its box is out of view. |

## What I did not check

- The bytes carried on streams mid-run were not compared with an independent model. I checked their padding (B19), where every value went and the final outputs; the digest also does not cover them, by design.
- Ledger citations were checked against the research reports in `research/`, not against the original papers.
- Compiler robustness on graphs other than M1–M3, the README demo and M1 at 320×320 (for example random graphs or `no_fuse` restarts) was not independently tested. I relied on nothing from the project's random-graph tests.
- Cross-machine reproducibility of `np.exp` and `np.tanh` was not tested; only one machine was used.
- Timeline tooltips were inspected for one cell per page only, and tile colours were not compared with `Program.schedule`.

## Scripts

All in `/tmp/claude-0/-home-user-ai-lab/c8af10d4-242d-50e2-9b7d-29e982e88ffc/scratchpad/verify/`:

- `common.py`: helpers, ledger parser, queue expansion, positions
- `check1_numeric.py`: check 1 (output in `check1_out.txt`)
- `check2_determinism.py`, `det_dump.py`: check 2
- `myvalidate.py`, `check3_schedule.py`: check 3
- `check3_mutation.py`, `check3_mutation_noexpect.py`: mutation testing (outputs `mutation_out.txt`, `mutation_noexpect_out.txt`)
- `check4_traceability.py`, `check4_sourced.py`, `check4_behaviour.py`: check 4 (outputs `check4_out.txt`, `check4_behaviour_out.txt`)
- `check5_viz.py`, `check5_dark.py`: check 5 (output `check5_out.txt`, screenshots in `shots/`, fresh run output in `out1/`)
- `check6_misc.py`, `check6_more.py`: check 6

## Re-verification after fixes

Rerun on 2026-11-14 at commit `8841250` ("Add verification report; fix findings V1-V5"), using the same scripts without changes. Outputs went to new files: `mutation_out_v2.txt`, `mutation_noexpect_out_v2.txt` and `check4_out_v2.txt`; `out1/` was regenerated.

**Regression reruns: no differences.**

- `python -m tsp.run all` still gives 68 / 96 / 465 cycles with unchanged trace digests (`c4cc9c76…`, `1a2ec987…`, `edf1da29…`).
- The regenerated `timelines/*` (html, json, asm) are byte-identical to fresh output.
- Check 1 passes: all milestones and seeds bit-exact.
- Check 2 passes: program and trace JSON byte-identical across 6 processes and hash seeds.
- Checks 3a–d pass: 0 errors on 9 runs, with the same counts as before.
- `check4_behaviour.py` passes, as do the README example, the 320×320 isca2020 run and `check6_more.py`.
- Check 5 passes: data, dispatch cells, lane cells and space-time all exact, with 0 console or page errors, light and dark.
- Project tests (supplementary): 358 passed.

**Mutation testing, rerun in full (2,226 mutants).**
- `Program.mem_names` names all 248 addresses that M3 uses, with none unnamed, and it survives the JSON round trip that my mutator uses.
- With tag checks on, the mutants that pass both the simulator and `validate.py` are now:

| class | M1 | M2 | M3 | output |
|---|---|---|---|---|
| `swap_read_addrs` | 0 (was 4) | 0 (was 17) | 0 (was 214) | — |
| `cross_swap_read_addrs` | 0 | 0 (was 2) | 0 (was 2) | — |
| `vxm_op` (add↔sub) | 1 | 2 | 7 | 8 wrong, **2 accidentally right** (M3 `n1_mse`, `n2_mse`: `ms − eps` vs `ms + eps`) |
| every other class | 0 | 0 | 0 | — |

- Total undetected: 10, down from 249. **None of the undetected mutants changes an address.** All 278 address mutants now raise `OperandTagError`, and so do all 56 `write_addr` mutants.
- With `expect` cleared, `validate.py` still flags every timing or stream mutant that runs to completion. The address check keeps working even then, because it uses the Read's own tag.

**Status of each finding**

| ID | Status | Evidence |
|---|---|---|
| V1 | **FIXED** (address part); **ACCEPTED LIMIT** (opcode part) | As above, 0 address mutants are undetected. Wrong arithmetic is now stated as a limit in `README.md:124`: "They cannot tell that an instruction does the wrong arithmetic … only the comparison with the NumPy references catches that." I judge this acceptable and clearly stated, since tags model routing, not semantics. One residual is worth knowing: 2 of 10 opcode mutants also pass the reference comparison (an `eps` of 1e-5 is lost in rounding), so that comparison is not a complete guard either. Two further limits are inherent to the design: `mem_names` is written by the same compiler whose placement it checks, so a self-consistent placement bug would not be caught; and the check is skipped for addresses without a name (`simulator.py:160`). `validate.py` itself still has no memory check, because the detection lives in the simulator. |
| V2 | **FIXED** | `README.md:121` now says the latencies are "the program's own `config.latency`, which defaults to the ledger values". This is accurate: `check6_more.py` still shows that a read=3 / abc=5 program validates clean, which matches the new wording. |
| V3 | **FIXED** | `graph.py:50` and `m1.py:19`, `m2.py:21`, `m3.py:65` now use `params.LANES_PER_SUPERLANE * params.TILES_TOY`. The rescan finds 0 unannotated literals and 26 `not-a-parameter` notes, all genuine: the remaining 16s are N_HIDDEN, H and V, which are model sizes. README:128-129 is now true. |
| V4 | **FIXED** | Ledger row G8 (`dossier.md:232`) now states the layout: 2k+5 positions, MXM planes share one position, SXM one inside it, ALUs share the VXM position; it is ASSUMED. `params.py:120,152` cite `ledger: G8`. The `isca2020()` docstring now reads "Published slice counts … with the same assumed latencies and stream-register layout (ledger G8)". All cited IDs exist, and the `params.py` values against the ledger are unchanged (the explained CHK rows only). |
| V5 | **FIXED** | The blank line is gone, so the Behaviour table B1–B22 is now one table. Cosmetic leftover: rows are still out of order (T18 before T17 at `dossier.md:260-261`, C4 before C3 at `:296-297`). |
| V6 | **STILL OPEN** (cosmetic, not changed by agreement) | Unchanged: labels are truncated at the default zoom, and the auto-scroll can hide units at the far end. |
| V7 | **NEW, Low (repo hygiene)** | 7 compiled files `tsp/__pycache__/*.cpython-313.pyc` are tracked in git (added in `0c80ed2`, modified again in `8841250`) despite `.gitignore` listing `__pycache__/` and `*.pyc`. This is harmless to results but adds noise to every diff. |

## Lead's note after re-verification

- V7 (compiled `.pyc` files tracked in git) was fixed after the re-verification run: the files were removed from the repository. This fix was not re-checked by the verifier.
- The out-of-order ledger rows noted under V5 (T18 before T17, C4 before C3) were put in order at the same time.
- V6 (label truncation at default zoom; the space-time view can scroll a dispatching unit out of view) remains open.

## Later check (2026-11-17)

A separate fact-check of the documents against the code, run on the working tree after commit `531d5f2` with Python 3.13.18. It did not repeat the checks above with independent scripts.

- **The scripts listed under "Scripts" are no longer available.** The scratch directory they were in has been removed, so the numbers in sections 1 to 6 and in the re-verification cannot be reproduced from this repository. They stand as a record of the runs of 2026-11-14.
- **Line numbers** in the findings refer to commit `8841250`. `README.md` has been edited since, so its line numbers (121, 124, 128-129) have moved; the sentences quoted are still there.
- **Test count.** `python3 -m pytest -q` gives `357 passed, 2 skipped`. The two skips are `test_browser_render` and `test_real_m1_run` in `tests/test_viz.py`, skipped because the Python `playwright` package is not installed on this machine. The "358 passed" above was a run with that package present, before one test was added (see below).
- **Regeneration.** `python3 -m tsp.run all --out <scratch>` prints 68 / 96 / 465 cycles with digests `c4cc9c76…`, `1a2ec987…`, `edf1da29…`, and all nine files are byte-identical to `timelines/`. Assembling each committed `*_program.asm` gives the same queues as a fresh compile.
- **Rendering.** The three committed timelines were loaded once each in headless Chromium through Node Playwright: 0 console errors, 0 page errors, 0 failed requests; dispatch cells 21 / 48 / 401 and lane cells 167 / 388 / 2951, equal to the traces; the space-time view matched the trace on one clicked cycle and after one ArrowRight.
- **README example.** It prints `[20  0] 68` when run from `sim_grok_1/`.
- **Compiler on other graphs** (listed above as not checked). The random-graph generator of `tests/test_e2e_random.py` was run on 200 further seeds (16 to 215): all compiled, validated clean and matched `evaluate` bit for bit. Ten hand-made graphs (a full 16x16 fp16 matrix, one matrix used by three matvecs, fan-out, one tensor as two outputs, an input used as matrix row and activation, 40 parallel chains, fp16 40x320 on `isca2020()`, and others) also passed; `broadcast` on `isca2020()` gave the documented `CompileError`. This uses the project's own `validate` and `evaluate`, so it is weaker evidence than the independent checks above.
- **V8, Low, fixed.** A graph built with `lanes=320` and a vector longer than 16 compiled for `ChipConfig.toy()` without complaint when it had no constants (giving a program whose input does not fit a MEM word), and failed with a bare NumPy `ValueError` in `emit.py` when it had one. `compile_graph` now raises `CompileError` for any vector longer than `config.lanes`; `tests/test_compiler_e2e.py::test_vector_longer_than_the_chip_is_rejected` covers it.
- **Not checked.** The dossier's quotations were not compared with the papers themselves: the Wayback Machine copy of the ISCA 2020 paper could not be fetched from this machine. Each item the README lists as sourced was traced to a ledger row and to a passage in `research/01` to `03` only.

## Later check (2026-11-20)

A second fact-check, run on the working tree after commit `a09edeb` with Python 3.13.18.

- **The ISCA 2020 paper was reached and read in full**, from `https://cdn.sanity.io/files/chol0sk5/production/16e7e13197dfe5f52d3b0ed62e29620662c38743.pdf` (14 pages, proceedings pages 145-158). This closes the "Not checked" item above for that paper: every quotation, page number, section label, Table I row and figure reading in `research/01_tsp_isca2020.md` was compared with it and stands. Six wrong page or section references in `research/04_static_scheduling_background.md` were corrected. Table I has no Countdown, Step or Iterations rows. The Fig. 4 register numbers are consistent (the first check's "must sum to 44" objection was mistaken; see report 01, section 2.4).
- **Two source conflicts, and what the code does.** (1) MEM Write: the simulator leaves the value on its stream after a Write (`tsp/hw/simulator.py`, `_dispatch`: a Write only files a memory commit; nothing removes the register contents). No test covered this; `tests/test_hw_sim.py::test_write_does_not_end_the_stream` now does, and `tests/test_compiler_e2e.py::test_compiled_programs_never_read_a_value_after_its_write` shows the milestones do not depend on the choice. The same check on the 216 random graphs of seeds 0 to 215 found 3,816 written values and no read after a Write. (2) Instructions per queue per cycle: `tsp/icu.py` returns at most one data instruction per `step`. `tests/test_icu.py::test_one_dispatch_per_cycle` already covered it; a cycle-loop test was added. Ledger rows B2 and T16 and the README now state both choices and their basis.
- **Countdown, Step, Iterations** (MEM address-loop instructions on Groq's slides): not modelled. Before this check only one sentence in dossier section 1.4 said so; they are now in ledger row B17 and in the README's "Left out" list.
- **V8 follow-up.** The length check added on 2026-11-17 was probed at the boundary: vectors, constants, broadcast results, matrix rows and matrix columns of exactly `lanes` compile and run correctly; `lanes + 1` is a `CompileError` in each case. One gap was closed: a matrix with more rows than lanes that no `matvec` uses compiled silently; `compile_graph` now rejects it, and a matrix with too many rows is reported by the matrix's own name. Tests: `test_length_check_boundary` (7 cases) and `test_matrix_with_too_many_rows_names_the_matrix`.
- **Test count.** `python3 -m pytest -q` gives `370 passed, 2 skipped` (13 tests added; the same two browser tests are skipped).
- **Regeneration.** `python3 -m tsp.run all --out <scratch>` after these changes: 68 / 96 / 465 cycles, the same three digests as on 2026-11-17, and all nine files byte-identical to `timelines/`.
- **README against the ledger.** Every simplification in the README's "Assumed" and "Left out" lists was traced to a ledger row, and every ASSUMED ledger row to the README. Rows that the README did not mention were added to it: B2 (Write), G14 (queue per unit), B16 (debug names and valid state), B18 (unit pipelining), and the T16 conflict. The "Left out" list now carries its ledger IDs.
- **Not re-checked.** The browser rendering of the timelines (files unchanged, byte-identical). Sources other than the ISCA 2020 paper were only sampled: 40 quotations from the 2026-11-17 corrections were searched in the downloaded texts and all were found.
