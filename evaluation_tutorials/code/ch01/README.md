# Chapter 1 code: Why Evals: Foundations, Taxonomy and Eval-Driven Development

Python 3.10+, standard library + NumPy only. No network, no API keys; every model, judge and system is a seeded mock.
Every script runs from any working directory and asserts the numbers quoted in the chapter.

| File | Section | Command | What it shows |
|---|---|---|---|
| `mini_harness.py` | 1.2 Anatomy | `python3 code/ch01/mini_harness.py` | Task / Trial / Grade dataclasses, seeded mock model, three graders, JSONL transcripts in `out/`, accuracy with task-level SE and 95% t-based CI [0.211, 0.723] (z-based [0.239, 0.695] for comparison); infrastructure-error handling (`status`/`error` on each trial; a 10% error-rate run gives 0.417 counting errors as fails vs 0.471 excluding them); `out/run_meta.json` reproducibility sidecar |
| `judge_always_pass.py` | 1.4 Graders | `python3 code/ch01/judge_always_pass.py` | Always-PASS judge: 95% agreement, kappa 0, TPR 0; realistic judge (kappa 0.388) with 95% Wilson CIs TPR [0.490, 0.943], TNR [0.849, 0.935] (imports `wilson_ci` from `wilson_defects.py`); dossier worked example (kappa 0.571) |
| `extraction.py` | 1.5 Metrics | `python3 code/ch01/extraction.py` | lm-eval GSM8K strict vs flexible regexes on 16 mocked outputs: 0.312 vs 0.625 vs human 0.875 |
| `passk_preview.py` | 1.5 sidebar | `python3 code/ch01/passk_preview.py` | n=10, c=3: pass@3 = 0.708, pass^3 = 0.008 |
| `wilson_defects.py` | 1.6 Estimate | `python3 code/ch01/wilson_defects.py` | Normal vs Wilson CI for 3% defects on 200; ~1,518 paired / ~3,027 unpaired items for a 3-point gap |
| `goodhart_holdout.py` | 1.7 Validity | `python3 code/ch01/goodhart_holdout.py` | Winner's curse: best of 200 configs on a 30-item dev set (0.912 dev vs 0.712 test) |
| `error_analysis.py` | 1.8 EDD | `python3 code/ch01/error_analysis.py` | 40 mocked traces: axial coding, Pareto table, transition-failure matrix |
| `regression_gate.py` | 1.8 EDD | `python3 code/ch01/regression_gate.py` | CI gate over `data/golden.jsonl`: regression must be 100%, capability Wilson lower bound >= floor; graduation |
| `test_regression_gate.py` | 1.8 EDD | `python3 -m pytest code/ch01/test_regression_gate.py` or `python3 code/ch01/test_regression_gate.py` | Same gate checks as pytest tests (optional) |

Data: `data/golden.jsonl` (40 tasks), `data/baseline.json` (capability floor).
Outputs (git-ignored): `out/transcripts.jsonl`, `out/transcripts_with_errors.jsonl`, `out/run_meta.json`, `out/golden_next.jsonl`.

Run everything: `python3 code/run_all.py ch01`.
