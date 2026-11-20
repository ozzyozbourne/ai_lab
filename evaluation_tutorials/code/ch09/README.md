# Chapter 9 code: Tooling, Production, RAG and Online Evaluation

Standard library + NumPy only. No framework installs, no network, no API keys: every model, judge,
retriever, user and guardrail is a seeded mock. `harbor_runner.py` also needs `bash` (no Docker).
Run any file from any directory, or all of them with `python3 code/run_all.py ch09`.
Every script asserts the numbers quoted in the chapter, so a passing run means the text and the code agree.

| File | Section | What it shows | Command |
|---|---|---|---|
| `mini_harness.py` | 9.2 `#harness` | Inspect-shaped `Sample` / `Task(dataset, solver, scorer)`, asyncio runner with a semaphore, JSONL log, accuracy 0.708 with naive vs clustered stderr (0.042 vs 0.049); a "pass"/"fail" scorer silently coerced to 0.000 | `python3 code/ch09/mini_harness.py` |
| `filter_ablation.py` | 9.3 `#benchmark-harnesses` | lm-eval gsm8k strict-match vs flexible-extract on 20 generations: 0.400 vs 0.700 | `python3 code/ch09/filter_ablation.py` |
| `harbor_runner.py` | 9.5 `#agent-harnesses` | Harbor-format task in a temp dir; Oracle (`solve.sh`) 1, null agent 0; empty-file agent beats a lazy verifier; test-peeking agent wins only when tests are visible | `python3 code/ch09/harbor_runner.py` |
| `swebench_cache_trap.py` | 9.5 `#agent-harnesses` | `--gold` 3/3, no-op 0/3; a fixed patch under a reused run_id reports a stale 1/3; content-addressed cache fixes it | `python3 code/ch09/swebench_cache_trap.py` |
| `assert_runner.py` | 9.6 `#app-testing` | promptfoo-like JSON tests (`data/assert_tests.json`): contains, icontains, regex, is-json, python, cost, latency; 2 prompts x 2 providers matrix | `python3 code/ch09/assert_runner.py` |
| `prompt_regression_ci.py` | 9.9 `#ci`, Fig 9.2 | 200-item JSONL suite (`data/regression_set.jsonl`), 3 assertions, response cache, naive single-run gate (37% false alarms) vs paired bootstrap gate with a 5-point margin and escalation | `python3 code/ch09/prompt_regression_ci.py` |
| `retrieval_metrics.py` | 9.10 `#retrieval` | P/R/hit@k, RR/MRR, AP/MAP, nDCG@5 0.578 (linear) / 0.608 (exp), RAGAS context precision 0.500, incomplete-judgment trap | `python3 code/ch09/retrieval_metrics.py` |
| `toy_rag.py` | 9.11 `#rag-generation`, Fig 9.3 | 30-doc corpus, pure-Python BM25, fabrication injection, mock NLI faithfulness (overlap misses number swaps), context recall vs k, NaN handling; ALCE-style citation recall/precision (20% wrong-doc citations: faithfulness 1.000, citation recall 0.809; 30% padded: precision 0.768) | `python3 code/ch09/toy_rag.py` |
| `semantic_entropy.py` | 9.12 `#hallucination` | SE = 0.802 nats for clusters {7,2,1}; AUROC 0.928 (semantic) vs 0.807 (lexical) | `python3 code/ch09/semantic_entropy.py` |
| `ppi_online.py` | 9.13 `#online`, Fig 9.4 | judge 0.80 - rectifier 0.06 = 0.74; Rogan-Gladen (0.807 - 0.40)/(0.95 - 0.40) = 0.740; 1,000 simulated weeks: judge-only coverage 0%, PPI 94.7% and 14% narrower than humans-only, Rogan-Gladen unbiased but widest (0.136) | `python3 code/ch09/ppi_online.py` |
| `feedback_bias.py` | 9.14 `#feedback` | thumbs-up 0.783 vs true 0.685; IPW fixes MAR selection (0.687) but not MNAR (0.445); a random 1% survey does | `python3 code/ch09/feedback_bias.py` |
| `ab_test_sim.py` | 9.15 `#ab-testing`, Fig 9.5 | n = 16 sigma^2/delta^2 = 9,600 per arm, simulated power 0.811, CUPED variance x0.640, peeking FPR 0.049 -> 0.249 over 20 looks; Pocock 2.68 vs O'Brien-Fleming-shaped boundary (final look 2.15, FPR 0.048); SRM chi-square check (50,500 vs 49,500: chi2 10.0, p 0.0016); ratio-metric A/A: naive per-request SE 0.0057 (FPR 0.326) vs delta-method SE 0.0116 (FPR 0.055) | `python3 code/ch09/ab_test_sim.py` |
| `guardrail_eval.py` | 9.16 `#guardrails` | regex vs mock-LLM vs cascade PII rails (precision, recall, false-block, p50/p95 latency); tool-call refund rail 5/8 -> 8/8 after hardening | `python3 code/ch09/guardrail_eval.py` |
| `slo_dashboard.py` | 9.17 `#slos` | p50/p95/p99 and error-budget burn after a release with a 4% slow tail (p95 3.62 -> 4.01 s stays in SLO, p99 4.41 -> 5.50 s breaks it); cost per request vs per successful task | `python3 code/ch09/slo_dashboard.py` |
| `drift_monitor.py` | 9.18 `#drift` | PSI 0.228, weekly PSI, numpy KS test, embedding-centroid drift, CUSUM/EWMA on judge scores, judge drift on a frozen anchor set | `python3 code/ch09/drift_monitor.py` |

`mini_harness.py` writes its log to `code/ch09/out/arith.jsonl`. Everything runs in a few seconds in total.
