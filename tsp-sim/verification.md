# Independent verification of tsp-sim

Date: 2026-11-14. Verifier: an agent that took no part in building the project.
Nothing under the project was changed except this file. All scripts used are in
`/tmp/claude-0/-home-user-ai-lab/109b6abd-cdbe-5605-bc9c-e12037e7a865/scratchpad/verify/`
(called "the scratch directory" below). Unless noted, run them from that directory with
`PYTHONPATH=/home/user/ai_lab/tsp-sim python3 <script>`.

My verdicts rest on my own code: a NumPy reference that does not import `tsp.reference` or
`tsp.numerics`, and a schedule checker that does not import `tsp.validate` or `tsp.hw` and rebuilds
stream contents from the instruction timing alone. I used the project's simulator only to produce
traces and outputs. I used its contract helpers (`isa.issue_cycles`, `isa.timing_key`,
`isa.from_bytes`, the `Program` layouts and the `Graph` read API) after reading them. I also ran the
project's own validator and tests, but only to compare their answers with mine.

## Summary

There were two rounds. Round 1 is the original verification. Round 2 re-checked only the three
PARTIAL items after the project made fixes (see "Re-verification after fixes" at the end). The
"Verdict" column shows round 1 → final. Rows that were PASS in round 1 were not re-run, except for
a regression run of the test suite and `run_milestones.py --paper-m1`, which still pass.

| Check | Sub-check | Verdict | Evidence (one line) |
|---|---|---|---|
| 1 Numerical | M1, M2 (integer) | PASS | Exact match with my int64 reference; 8 extra seeds per model also exact |
| 1 Numerical | M1 320×320 on the paper chip | PASS | All 320 outputs exact |
| 1 Numerical | M3 against a reference that models the stated numerics | PASS | logits, k and v bit-exact, including 8 extra seeds |
| 1 Numerical | M3 against plain float64 | PASS | logits max abs diff 2.14e-4, max rel 9.3e-3 (F16 rounding); k and v diff 0 |
| 1 Numerical | M3 is a real decode step | PASS | Softmax weights sum to 1.00016; 7 cached positions plus self; lanes 8–15 masked to exactly 0 |
| 2 Determinism | Repeat run in one process | PASS | Identical trace JSON and n_cycles for all 4 milestones |
| 2 Determinism | Separate processes, PYTHONHASHSEED 0, 1, 4242, random | PASS | All trace JSON, listings, queues, n_cycles and outputs byte-identical |
| 2 Determinism | Recompile gives the same program | PASS | `queues` and listing equal over 3 compiles |
| 2 Determinism | Schedule independent of data | PASS | Seeds 101/202/303: same queues, events and occupancy tags; different outputs |
| 3a Schedule | No cell driven twice; no live value overwritten | PASS | My reconstruction finds 0 double drives and 0 overwritten live values; occupancy equals the trace on every cycle |
| 3b Schedule | Issue width, MEM ports, MXM rows, fp16 rule | PASS | 0 violations; all 22 MATVECs use exactly the rows and activation the graph implies |
| 3c Schedule | Every operand on the exact cycle | PASS | All samples see the expected tag; all 2,482 one-cycle moves are detected (1,186 with a free slot) |
| 3 Break the checks | Crafted invalid programs | PARTIAL → PASS (one residual gap, see note) | Round 1: the validator accepted a same-tag impostor that changes the outputs. Round 2: new check F rejects it on M1, M2 and M3, plus 3 new variants. It still accepts a trace whose run used a memory image different from the program's layouts (finding N1, low severity) |
| 4 Traceability | `tsp/config.py`, line by line | PASS | Every literal carries a ledger ID, or is a hash length marked as not a machine parameter |
| 4 Traceability | Rest of `tsp/` | PARTIAL → PASS | Round 2: the 3 constants now derive from `DType`, carry an ID or are marked; the re-scan finds no untagged machine parameter |
| 4 Traceability | Ledger values against code, both presets | PASS | 16 parameters and 14 timing entries match; no ID in the code is missing from the ledger |
| 4 Traceability | SOURCED entries against raw reports (≈25 checked) | PARTIAL → PASS | Round 2: L-X1, L-M3 and L-V7 now separate the sourced part from the inferred or assumed part, consistent with the raw reports |
| 4 Traceability | README and outputs present no assumed number as fact | PASS | Every cycle or ns figure is labelled as assumed or as a unit conversion |
| 5 Visualisation | Page loads, no errors, no network | PASS | 0 console messages, 0 page errors, 0 requests besides the file, light and dark |
| 5 Visualisation | Embedded trace equals the simulator's | PASS | Parsed JSON equal to a fresh trace; n_cycles 49/100/402 |
| 5 Visualisation | Drawing matches the trace | PASS | Blocks 34/209/655 at the right cycles; all 37/224/674 flights drawn correctly; chip view equal to my occupancy on every cycle |
| 5 Visualisation | Interaction | PASS | Slider, number box, arrow/Shift/Home/End keys, buttons, Play, canvas click, hover, idle toggle |
| 5 Visualisation | Visual inspection | PASS | No overlapping or clipped text, empty areas or unreadable colours found |
| Project tests | `python3 -m pytest -q` | PASS | Round 1: 307 passed in 7.9 s. Round 2: 308 passed in 6.1 s |

**Correction to round 1.** Round 1 said "34 of 36 crafted programs caught". That count was wrong.
`craft.py` builds 27 invalid programs (9 each for M1, M2 and M3) plus 3 tampered traces of a valid
M1 program.

- In round 1, the simulator or the project validator rejected 21 of the 27 programs and all 3 tampered traces. My own checker rejected all 27 programs.
- The 6 programs the project missed were the same-tag impostor (×3) and the MATVEC with k−1 rows (×3). The k−1 case is a semantic error, outside the validator's timing scope, and the comparison with the reference catches it.
- The findings themselves are unchanged.

# Round 1 (original verification)

The sections below are unchanged from round 1, apart from marked corrections.

## Check 1: numerical correctness

**What I did.** `numcheck.py` evaluates each graph node by node through the documented read API
(`graph.nodes`, `matrices`, `constants`, `outputs`). It does not import `tsp.reference` or
`tsp.numerics`. It provides two references.

The **modelled reference** reproduces the stated numerics:

- Integers are computed in int64 and wrapped to int32.
- `requant` is `clip(a >> imm, -128, 127)`.
- F16 matrix products form each lane's sum exactly with `fractions.Fraction` from the F16 inputs, then round it once to F32 with my own round-to-nearest-even routine.
- Products with more than one input tile (W2 in M3, W1 in M2) are rounded per tile and then summed left to right in F32 (plan 3.3).
- `matvec_cols` is one exact sum, rounded once.
- F32 elementwise operations use numpy float32.
- `exp`, `rsqrt` and `tanh` are computed with numpy in float64 and rounded to F32. This is a different implementation from the project's `math.exp`.
- Casts use `astype`.

The **float64 reference** skips all F16/F32 rounding and tiling.

`numseeds.py` repeats the bit-exact comparison for seeds 10–17 of every model and checks the data
ranges given in plan section 6.

**Results** (`numcheck.out`, `numseeds.out`):

| Milestone | Cycles | Output | Bit-exact vs my modelled ref | vs float64 |
|---|---|---|---|---|
| M1 (toy) | 49 | y int32[24] | yes | equal |
| M2 (toy) | 100 | y int32[10] | yes | equal |
| M3 (toy) | 402 | logits f32[32] | yes | max abs 2.14e-4, max rel 9.27e-3 (largest value 0.94) |
| M3 | | k f32[16], v f32[16] | yes | 0 (the inputs are exact in F16, so the sums are exact) |
| M1 320×320 (paper) | 103 | y int32[320] | yes | equal |

The M3 differences from float64 come from the documented F16 casts (`c16`) before every matrix
product. My modelled reference reproduces them bit for bit. All 24 extra seed runs are bit-exact.
The data ranges match plan section 6:

- int8 weights −16..15
- biases within −1000..1000
- F16 weights are multiples of 1/256 in [−0.25, 0.25]
- x is in multiples of 1/64 in [−1, 1]
- mask is 0 for lanes < 8 and −1e4 above
- scale is 0.25
- Kc rows 7..15 are zero
- there are 7 cached V vectors

**M3 is a decode step.**

- The graph matches plan section 6 node for node (47 nodes).
- From my reference values:
  - softmax weights over lanes 0..7 sum to 1.000161, and lanes 8..15 are exactly 0;
  - `s_cache` is zero in lanes 7..15;
  - `s_self` is non-zero only in lane 7, where it equals q·k (−0.285291 against −0.285298 in float64);
  - the attention output equals Σ_{i<7} aᵢVᵢ + a₇v to within 1.0e-4;
  - the weights `a` differ from a float64 softmax of the same scores by at most 2.3e-5.
- On the chip itself: I decoded the values parked in memory after the run (`a16`, `e`, `e16`, `h`). All four equal my reference bit for bit, and the chip's `a16` lanes 0..7 sum to 1.000183.
- The scores stay within ±0.56, far inside the "±16" margin the plan states.

## Check 2: determinism

- `detdump.py` was run as 4 separate processes with `PYTHONHASHSEED` = 0, 1, 4242 and `random`. Each process writes the full trace JSON, listing, `repr(queues)`, n_cycles and output bytes for all 4 milestones. `diff -rq` found every file byte-identical. The traces also equal the files `run_milestones.py` wrote to `out/`. The SHA-256 of the M1 and M2 traces equals `tests/golden_digests.json`.
- `detinproc.py` checks four more things for every milestone, all true:
  - three compilations (two of one graph object, one of a freshly built graph) give equal `queues` and listings;
  - three runs give identical trace JSON and n_cycles;
  - for data seeds 101, 202 and 303: queues, listings, n_cycles, the full event list and the per-cycle occupancy tags are equal;
  - for the same seeds, the per-cycle byte digests, the outputs and the constants differ.
- A grep of `tsp/compiler` found no iteration over sets, no `hash()`, no randomness, no time and no environment input.

## Check 3: schedule validity

### 3a–3c: my checker

**How it works.** `schedcheck.py` reconstructs everything from `program.queues` alone:

- Issue cycle comes from the queue; sample = issue + d_skew; visible = sample + d_func.
- A driven plane is placed in cell (dir, stream, position) at its visible cycle. Cells move one position per cycle and fall off the edges. A drive replaces whatever would have arrived.
- It keeps its own memory model. Initial tags come from `program.inputs` layouts. A Write commits at sample + d_func(WRITE), and a Read sees a word only if it was committed by its sample cycle.
- It keeps its own MXM weight buffers. A row commits at sample + d_func(IW). It applies the L-X9 clearing rules and the issue-time rule for plane .1.

**What it checks:**

- an empty sample;
- a sampled tag different from the expected one;
- a double drive;
- an overwritten live value (a wanted flight on the same diagonal upstream was replaced);
- queue entry width, and MEM per-entry composition;
- MEM ports per slice per sample cycle (at most 1 Read and 1 Write, on different banks);
- MATVEC rows: installed by the sample cycle, correct dtype, tag equal to `expect_rows[r]`;
- the fp16 two-plane rule;
- the L-X3 stream limit and the `k` range;
- stream-group alignment and range, and the MXM directions (L-X6);
- tag uniqueness: every computed tag has exactly one producing instruction, and host tags are unique and disjoint from computed tags, so a tag match identifies the producer;
- semantics: for every MATVEC, `expect_rows` and the activation tag must be exactly the weight columns and input tile the graph node implies.

At the end it compares its own event multiset (issue, sample, drive, mem_read, mem_write, iw_row,
matvec_row, each with its tag) and its per-cycle occupancy with the trace.

**Results** (`schedcheck.out`):

| | Instructions | Samples | Flights | Violations | Events mine = trace | Occupancy equal | n_cycles |
|---|---|---|---|---|---|---|---|
| M1 | 34 | 37 | 37 | 0 | 177 = 177 | 49/49 cycles | 49 = 49 |
| M2 | 209 | 224 | 224 | 0 | 1113 = 1113 | 100/100 | 100 = 100 |
| M3 | 655 | 678 | 674 | 0 | 3025 = 3025 | 402/402 | 402 = 402 |
| M1 paper | 352 | 337 | 337 | 0 | 1995 = 1995 | 103/103 | 103 = 103 |

- No flight is ever unread.
- In M3, 4 flights are overwritten after their last read. These are dead tails and are allowed.
- The tightest weight install is a MATVEC sampling in the very cycle its rows become usable (slack 0), which is allowed.
- `perturbed.py` repeats all of this for programs compiled under two other latency sets: one with d_skew from 0 to 2 and d_func values changed, and one with slower memory. All six runs show 0 violations, events and occupancy equal to the trace, and bit-exact outputs. Cycle counts change, for example M3 goes 402 → 443 and 456.

Note on the project validator's count. Its check D reports 3021 checked items for M3 while the
trace has 3025 events. This is not a defect: `validate._expected_events` compares sample events as
a set, and `rr = r*r` samples the same 4 streams twice. My checker counts the duplicates and
matches all 3025.

**Exactness (±1 cycle).** `shift1.py <label>` moves every instruction of a milestone one cycle
earlier and one cycle later, one at a time, and runs the simulator, the project validator and my
checker on the result.

| | Trials | Detected | Trials with a free slot (no queue collision) | Detected among them |
|---|---|---|---|---|
| M1 | 67 | 67 | 53 | 53 |
| M2 | 416 | 416 | 250 | 250 |
| M3 | 1307 | 1307 | 829 | 829 |
| M1 paper | 702 | 702 | 54 | 54 |

Example per milestone, moving the first MATVEC, with the simulator's fault:

| Milestone | Instruction | −1 | +1 |
|---|---|---|---|
| M1 | MXM_W.0 at cycle 21 | queue collision | fault 1, empty sample |
| M2 | MXM_W.0 at cycle 25 | fault 1 | queue collision |
| M3 | MXM_W.0 at cycle 28 | fault 1 | fault 1 |
| M1 paper | MXM_W.0 at cycle 47 | fault 1 | fault 1 |

- 27 moved programs ran without a simulator fault. The project validator (checks A, B and sometimes C) and my checker rejected all 27.
- In two of them the outputs did not change: M3 `MEM_W15`/`MEM_W14 WRITE s_self.t0#0/#1` moved 1 cycle early. The wrong low bytes of `s_self` are lost in later F16 casts. Only the schedule checks catch these; an output comparison alone would not.

### Breaking the checks: crafted invalid programs (`craft.py`, output in `craft.out`)

Each case was built for M1, M2 and M3 (M3 also got the fp16 case). "Validator (partial trace)"
means the project's `validate()` was run on the partial trace that came with the SimFault.

| Crafted program | Simulator | Project validator | My checker | Outputs |
|---|---|---|---|---|
| Extra Read upstream overwrites a live operand (e.g. M1: MEM_W15 at cycle 17 onto W0 before MXM_W.0 reads `x.t0` at 21) | no fault | rejects A,B | rejects (live_value_overwritten, wrong_value) | changed |
| **Same overwrite, but the word read carries the victim's tag (`x.t0#0` / `x16.t0#0`) and other data** | no fault | **ACCEPTS** (M1, M2, M3) | rejects (tag_not_unique) | **changed** |
| Two Reads in one MEM entry | fault 7 | rejects C,D | rejects | – |
| Read and Write on the same bank in one cycle | fault 3 | rejects C,D | rejects | – |
| VXM operand one cycle late | fault 1 | rejects D (C,D for M3) | rejects | – |
| Two ALUs drive one cell in one cycle | fault 2 | rejects D (C,D for M3) | rejects | – |
| IW sampling 17 streams | fault 8 | rejects C,D | rejects (iw_streams) | – |
| Read of a never-written word | fault 4 | rejects C,D | rejects | – |
| M3: instruction on MXM_W.1 while MXM_W.0 holds F16 rows | fault 6 | rejects C,D | rejects (fp16_rule) | – |
| MATVEC with k−1 rows and consistently shortened expect_rows (a semantic error, not a timing one) | no fault | accepts | rejects (matvec_semantics) | changed |
| Good M1 program; trace with one occupancy cell removed / one sample tag edited / one drive deleted | – | rejects E / A / B,D,E | – | – |

The "parked word overwritten before read-back" case was built by the script but found no matching
slot in these programs, so it did not run.

**Defect (validator) — the impostor case.**

- `tsp/validate.py` checks A and B compare tags only. Plan 3.4 says tags are unique per stored vector, but the validator never checks this.
- So a program in which a live operand is overwritten by a different value carrying the same tag passes all five checks, although the outputs are wrong. The README and the validator's docstring say it proves "no live value was overwritten"; in this case that is false.
- Reproduce: `craft.py`, function `case_impostor`. It adds a host tensor `evil` whose tile tag is `x.t0`, at an unused address of MEM_W15, plus a Read of it at cycle 17 onto W0 (M1). For M2 the cycle is 21; for M3 it is 24, with tag `x16.t0`.
- Suggested fix: in `validate`, fail if a computed tag (the `out` tags of VOp, MatVec and SXM instructions) is produced by more than one instruction, if a host tag (from `program.inputs`) occurs at more than one address, or if a computed tag equals a host tag.
- The compiled milestone programs satisfy all three conditions; my checker verifies this. So the gap does not hide an error in the shipped programs, but the validator does not prove the property it claims.

The k−1 case is outside the validator's stated scope: it checks timing, not semantics. The
comparison with the reference catches it.

## Check 4: traceability

**`tsp/config.py`, line by line.** Every numeric literal carries an `L-` ID:

- the presets (lines with L-G1/G2/G5/G10, L-M1/M2, L-V1, L-X1/X3, L-T10, L-C1, L-K7);
- the timing table (L-T2..T9);
- `n_positions`, `vxm_pos` and `pos()` (L-G9, L-G11);
- `issue_width` (L-I2);
- `SXM_UNITS` (L-S2).

The exception is the fingerprint display length (16), which is marked "not a machine parameter".
Every ID used anywhere in `tsp/` exists in dossier section 7, which has 65 entries
(`literals.py`, `literals.out`).

**The rest of `tsp/`.** An AST scan finds 509 numeric literals. Untagged ones other than −1, 0, 1
and 2 are model shapes and data ranges in `tsp/models` (model definitions, not machine
parameters), plus display/indexing constants in `validate.py`. Three constants derive from machine
parameters and carry no ledger ID:

1. `tsp/compiler/tiling.py:81`: `config.lanes // 2 if has_f16 else config.lanes`. The 2 is the fp16 width (L-G7/L-X2/L-X8). It is exempt from the project's ledger test only because that test allows the literal 2. `DType.F16.nbytes` would make the link explicit.
2. `tsp/validate.py:207`: `if n not in (1, 2, 4)` hard-codes the stream-group widths (L-G6/L-G7) instead of deriving them from `DType.nbytes`. `validate.py` is not scanned by `tests/check/test_check_ledger.py`.
3. `tsp/graph.py:145`: `if not 0 <= shift < 32` is the int32 bit width. This is not really a machine parameter, but it is untagged; `hw/vxm.py` derives the same bound from `DType.I32.nbytes`.

Cosmetic: the fault codes in `tsp/hw/errors.py:7–13` (`MEM_PORT = 3  # (L-M4, L-M5)` and so on)
carry ledger IDs that describe the rule, not the number. They satisfy the lint, but the value 3
does not come from L-M4.

The viz JavaScript hard-codes no machine parameters; it reads the chip JSON. 17 ledger entries
are rules or abstractions (L-G12 hop rate, L-G13, L-V3 and so on) that are implemented but never
cited by ID in the code. This is acceptable, because they carry no numeric value.

**Ledger values against code.** All of these match, for both presets:

- L-G1 16/16, L-G2 20/2, L-G3 320/32, L-G5 32, L-G10 44/16, L-G11 93/37;
- L-M1 2, L-M2 4096/64;
- L-V1 16, L-X1 2, L-X2 K = 320/32 (int8) and 160/16 (fp16), L-X3 16;
- L-T10 65535, L-C1 900 MHz, L-K7 100000;
- timing READ (0,2), WRITE (0,1), VARITH (0,1), VTRANS (0,3), IW (0,1), MATVEC (0,3), SXM (0,1);
- L-I2: MEM 2, others 1;
- L-S2: 3 SXM units;
- L-G6/G7: nbytes 1/2/4/4;
- L-G9: slice order.

L-G11's claim of "92 hops" for the paper preset is consistent with 93 positions. The README's
latency list agrees with the ledger.

**SOURCED entries against the raw reports.** I opened `research/raw/01-tsp-isca2020.md` §2.1–2.9
and `02-tsp-multiprocessor-isca2022.md` §7 and checked these entries against the quoted text:

- L-G1, G2, G3, G4, G5, G6, G8, G9, G10, G12, G13, G14, G16;
- L-T1, L-T10, L-C1;
- L-M1, M3, M4;
- L-V1, V4, V7;
- L-X1, X2, X3, X4, X6;
- L-S1, S4;
- L-K4, L-I2 (as the source sentence of an ASSUMED entry).

Every cited section exists and supports the main value. Three entries are labelled SOURCED but are
partly inference:

- **L-X1** ("2 per hemisphere"): R1 §2.8 has "four 320×320 planes" from the paper, but the two-per-hemisphere split is marked [I], an inference from the figure.
- **L-M3** ("a Read puts a full vector on one stream"): the cited R1 §2.7 gives this as [I]. It is supported as [S] only by a slide quoted in R2 §7, which the ledger does not cite.
- **L-V7** ("int32 add/sub/mul wrap"): the source names `add_mod` and `mul_mod` only; the wrapping `sub` is an extrapolation.

These are labelling issues, not wrong values.

**README and generated outputs.**

- The README says every latency is assumed and that cycle counts "follow from the assumed latencies".
- `run_milestones.py` prints the ns figure as "a unit conversion, not a prediction: the latencies are assumed".
- The HTML header says "the clock is a nominal published figure; the cycle latencies in this simulator are assumptions".
- `out/summary.json` holds cycle counts only.
- The README's numbers are correct: 49/34, 100/209, 402/655, 103/352, and 307 tests.

I found no assumed number presented as real-chip performance.

## Check 5: visualisation

**Steps.**

1. Ran `python3 run_milestones.py` to regenerate the pages; it reported "ALL CHECKS PASSED".
2. `vizexpect.py` parses the trace JSON embedded in each `out/m*_timeline.html` and compares it with a trace produced fresh in that process. All three are equal, with n_cycles 49/100/402. It also writes my expected drawing content (issue cycles per unit, my own flights, my own per-cycle occupancy) to `vizexp_<m>.json`. The pages contain no `http`, no `//`, no `src` and no `href`.
3. `node viz.js` loads each page from `file://` in headless Chromium, both light and dark, at 1280×900 and deviceScaleFactor 1. Before the page script runs, it wraps `CanvasRenderingContext2D.fillRect` to log every rectangle drawn on the Gantt canvas. Results are in `viz.out` and `viz_report.json`; screenshots are in `shots/`.

**Results** (all three milestones, both schemes):

- **Loading:** 0 console messages, 0 page errors, 0 network requests besides the file itself, no horizontal page overflow.
- **Instruction blocks** (the rectangles of height 12) number 34/209/655, equal to the issue events, with the right per-row counts in every row. Fitting px/cycle to the block x positions puts every block on its expected issue cycle; 0 blocks are off.
- **Stream bars** (the rectangles of height 10): every one of 37/224/674 flights has its solid live bar from the drive cycle to the last read + 1, matching my reconstruction to within 0.01 cycle. Every dead tail (16/82/214) is drawn with its hatch fill up to the cycle where it is overwritten or leaves the chip. There are no extra bars, and bars appear only on lanes that have drives (24/32/32).
- **Chip view:** cells were compared with my own occupancy at cycles 0, 1, NC/3, NC/2, NC−2 and NC−1 through the number box, then at every cycle 0..NC−1 by pressing ArrowRight from Home. Every cycle matched; pressing past the end stays on the last cycle.
- **Interaction:**
  - Home → 0, Shift+→ → 10, ← → 9, End → last cycle;
  - the first, next, last and previous buttons work;
  - the slider `input` event sets the number box and the cells;
  - the number box clamps 99999 and −5;
  - clicking the canvas at cycle 24/50/201 selects that cycle;
  - Play advances about 4 cycles in 0.7 s;
  - hovering a chip cell shows its tag and live/dead state and highlights the value;
  - "Show idle rows" adds rows, and unchecking it restores them.
- **Visual inspection.** I looked at `m1_light_full.png`, `m1_dark_chip_mid.png`, `m3_light_view.png`, `m3_dark_zoomed.png` and `m3_light_chip_mid.png`. I found no overlapping or clipped text. Opcode and value labels are suppressed where there is no room; this is by design, and hovering gives the tag. Both schemes have readable contrast, the chip grid and slice labels are legible, and there are no empty areas besides the intentionally blank chip view at cycle 0.

During my first run, 78–934 bar "mismatches" and a failed canvas click were reported. Both came
from my test, not the page: I had read px/cycle from the rounded zoom label, and earlier button
clicks had scrolled the canvas off-screen. After fixing the test, everything matched.

## Project test suite

`python3 -m pytest -q`: 307 passed in 7.9 s. Things I noticed while reading:

- Four tests in `tests/compiler/test_comp_e2e.py` have no `assert` in their own body (`test_milestone_mirrors_run_bit_exact`, `test_small_graphs_run_bit_exact`, `test_paper_m1_320`, `test_models_package`). They do assert through the `run_and_compare` helper, so they can fail.
- `run_and_compare` compares the run only with `tsp.reference.evaluate`, which uses the same `tsp.numerics` kernels as the simulator. For floats, this guards scheduling and data movement, not the arithmetic itself. My independent reference covers the arithmetic.
- `tests/check/test_check_ledger.py` scans only `tsp/hw` and `tsp/compiler` (and config, isa and numerics for IDs), and allows the literal 2. This is why the untagged constants in check 4 are not caught.

## Not verified

- **Behaviour on other platforms.** `exp` goes through the C library, so M3 may differ in the last bit on other machines, as the README says. Everything here ran on one Linux machine with Python 3.13.18.
- **Validator check B on its own.** I did not test it separately against a simulator stream bug. Instead, my own replay agreed with the simulator event by event.
- **The "parked word overwritten before read-back" case** did not run (see above).
- **Paper-scale M1 pages.** No timeline is generated for paper-scale M1, so it was not checked in the browser.
- **Raw reports against primary papers.** I checked ledger entries against the raw research reports only, not against the primary papers themselves.
- **Mobile layouts and screen readers** were not tested.

# Re-verification after fixes (round 2)

Scope: only the three round-1 PARTIAL items, plus one regression run. Scripts are in the same
scratch directory: `craft.py` (re-run; output `craft_r2.out`), `craft2.py` and `craft3.py` (new
variants; output `craft2.out` and `craft3.out`), and `literals.py` (output `literals_r2.out`).

## Regression

- `python3 -m pytest -q`: 308 passed in 6.1 s.
- `python3 run_milestones.py --paper-m1`: "ALL CHECKS PASSED". M1, M2, M3 and paper-scale M1 pass validator checks A–F, with F checking 62/374/1128/662 items. All outputs are bit-exact. The cycle counts are unchanged at 49/100/402/103.
- My own checker (`schedcheck.py`) still finds 0 violations on all four programs.

## Item 1: the validator accepted a same-tag impostor — PARTIAL → PASS, with one residual gap (N1)

**What changed.** `tsp/validate.py` has a new check F, "tag identity" (`_check_f`, about line 564;
plan section 7, row F). I read it. It fails a run when:

- a computed tag is driven by more than one instruction;
- a host tag is read from more than one location, or one location shows two host tags;
- a computed tag is read from a word whose last Write at least d_func(WRITE) earlier did not carry that tag;
- two host layouts name the same tag, or a host layout reuses a computed tag.

**Re-run of all crafted programs** (`craft.py`, 27 programs and 3 tampered traces):

- The same-tag impostor is now rejected by check F on M1, M2 and M3. In round 1 the validator accepted all three.
- "Two ALUs drive one cell" is now additionally rejected by F.
- Every other result is as in round 1.
- In total, the simulator or validator rejects 24 of 27 programs and all 3 tampered traces. The 3 not rejected are the MATVEC with k−1 rows (a semantic error, outside the validator's timing scope; the reference catches it). My checker still rejects all 27.
- The three unmodified programs still pass every check.

**New variants built to get around check F:**

| Variant (M1/M2/M3 unless noted) | Simulator | Validator | My checker | Outputs |
|---|---|---|---|---|
| Impostor through a Write (M2, M3): an idle ALU computes SUB instead of ADD with the **same result tags** in the same cycle, on another stream group, and the genuine parking Write samples the impostor's plane. The parked word holds wrong data with the right tag, and the read-back delivers it. M1 has no parked binary VXM result to imitate. | no fault | **rejects F** | rejects | changed |
| A host layout reuses a computed tag (`Wx.t0#0`, `W1x.t1.p0#0`, `q.t0#0`), and a Read of that host word overwrites the computed flight before its consumer | no fault | **rejects F** | rejects | changed |
| One VXM result whose 4 planes all carry the plane-0 tag | no fault | rejects A,B,F | rejects | unchanged |
| A parked word overwritten by an extra Write before its read-back (M3; no slot in M1/M2) | no fault | rejects A,B | rejects | unchanged |
| **Memory image differs from the layouts:** one host Read is redirected to an unused address in the same slice, and the run's initial memory puts a word there with the victim's tag (`W.o0.c0#0`, `W1.o1.c0#0`, `Wq.o0.c0#0`) and other data. The program's layouts are unchanged. Run with `Chip(config).run(queues, image)`, not `run_program`. | no fault | **ACCEPTS** | rejects (unwritten_read, weight_row, wrong_value) | changed |

**Residual gap N1 (new finding, low severity).**

- Check F verifies that a host tag is read from only one location, but not that this location is where `program.inputs` places that tag.
- So the validator accepts a trace from a run whose initial memory is not the program's own memory image, if each host tag still appears at only one address.
- This cannot happen through `run_program`, which builds memory from the layouts: there, the redirected Read faults (unwritten word) or reads another tag, and A fails. It needs a host or runtime that loads memory inconsistently with the program.
- Within that limit, I also argue that F is sound for runs made with `run_program`:
  - the only sources of tags are host layouts (unique, and disjoint from computed tags under F), computing instructions (each computed tag has a single producer under F), and Writes and Reads, which copy a tag together with its bytes;
  - by induction, every flight or word with a given tag then holds the same bytes, so A and B tag equality implies the right data.
- Reproduce: `craft2.py`, function `v_image_mismatch`.
- Suggested fix: in `_check_f`, compare each host-tag `mem_read` location with the `PlaneLoc` given for that tag in `program.inputs`.

Verdict: the defect reported in round 1 is fixed, and every program-level variant I built is
caught. N1 remains as a documented limitation of low severity.

## Item 2: untagged constants outside `config.py` — PARTIAL → PASS

Re-scan with `literals.py` (513 numeric literals in `tsp/`):

- `tsp/compiler/tiling.py:81` is now `config.lanes // DType.F16.nbytes ...   # L-X2: K <= lanes/2 for fp16`.
- `tsp/validate.py:207` is now `if n not in sorted({d.nbytes for d in DType}):   # L-G6, L-G7`.
- `tsp/graph.py:145` now uses `bits = 8 * DType.I32.nbytes  # not a machine parameter: bits per byte`.
- `tsp/hw/errors.py:4–5` now explains that the fault codes are rule numbers (labels), not machine parameters, and that the ledger IDs name the rule each fault enforces.

The untagged literals remaining outside `tsp/models` are indices and display counts in
`validate.py` (tuple unpacking `k[:6]`, `CHECK_NAMES[3]`, "show the first 3"), `ndim != 2` shape
checks, a sort-key index, and the fault code `DOUBLE_DRIVE = 2`. None is a machine parameter. The
remaining `config.lanes // 2` at `validate.py:270` is tagged L-X2, as it was in round 1.

## Item 3: SOURCED labels — PARTIAL → PASS

I re-read the three rows of dossier section 7 against the raw reports:

- **L-X1.** Status is now "SOURCED (4 planes); INFERRED (2 per hemisphere)". This matches R1 §2.8: "four (4) independent 320×320 … planes" is marked [P], and "two MXM planes per hemisphere at the outer edges" is marked [I], from Fig. 2 and Fig. 5.
- **L-M3.** Status is now INFERRED. It cites R1 §2.7, which gives the 20 tiles × 16-byte-word arithmetic as [I], and R2 §7, which quotes the 2022 slide "A read from a single MEM slice creates a 320Byte stream" as [S]. Both are present in the raw reports.
- **L-V7.** Status is now "SOURCED for add and mul; ASSUMED for sub". This matches R1 §2.6: "saturating and modulo variants `add_sat, add_mod, mul_sat, mul_mod`", with no wrapping subtract.

## Remaining open items after round 2

- **N1:** the validator does not cross-check host-read locations against `program.inputs` (low severity; see item 1).
- Everything in "Not verified" above still applies.

---

## Note added by the lead engineer after verification (not part of the verifier's report)

Finding N1 was addressed after the verifier finished: check F in `tsp/validate.py`
now also requires every host word to be read from the location the program's
layout gives for its tag, and a unit test covers it
(`test_f_fails_when_host_word_is_read_from_the_wrong_place`). The test suite
(309 tests) and all four milestone runs pass with this change. **This fix has not
been re-checked by the independent verifier**: the brief allowed one re-run of
the failed checks, and N1 was found during that re-run.
