# Chapter 2 code: Benchmarks and Metrics for LLMs

Standard library + NumPy only. No network, no API keys; every model is a seeded mock.
Run any file from any directory, or all of them with `python3 code/run_all.py ch02`.

| File | Section | What it shows | Command |
|---|---|---|---|
| `text_metrics.py` | 2.3 `#text-metrics` | SQuAD EM/F1, BLEU (clipping, BP, smoothing, corpus vs sentence), ROUGE-1/L, toy BERTScore; BLEU = 0 vs ROUGE-L = 0.769; IFEval prompt- vs instruction-level, strict vs loose (1/3, 3/6, 2/3, 4/6) | `python3 code/ch02/text_metrics.py` |
| `mock_mc_eval.py` | 2.4 `#logprob`, Fig 2.3 | acc / acc_norm / acc_bytes / acc_mutual_info on a mock LM; letter prior and the permutation fix; PPL = 3.364, bits-per-byte | `python3 code/ch02/mock_mc_eval.py` |
| `pass_at_k.py` | 2.5 `#pass-at-k`, Fig 2.4 | unbiased pass@k (combinatorial and product forms), plug-in bias 0.3485 vs 0.4095, pass@k vs k table, variance vs naive; greedy pass@1 vs avg@8 vs maj@8 vs pass@k (0.60 / 0.40 / 0.60 / 0.80); weak tests (EvalPlus-style); best temperature depends on k (full 0.1-step grid printed) | `python3 code/ch02/pass_at_k.py` |
| `calibration.py` | 2.6 `#calibration`, Fig 2.5 | ECE (equal-width / equal-mass) = 0.305, MCE, Brier, HLE-style RMS calibration error (equal-mass bins of beta, last bin skipped: 0.2525 vs 0.3160), temperature scaling, SimpleQA F; confidence-target penalty t/(1-t) (-1.20 vs -0.65 at t = 0.75) | `python3 code/ch02/calibration.py` |
| `arena_ratings.py` | 2.7 `#preferences` | online Elo in two orders, Bradley-Terry by Newton, ties as 0.5 vs dropped, bootstrap CIs with ratings centred on mean 1000 (no zero-width interval), style control with a length covariate | `python3 code/ch02/arena_ratings.py` |
| `normalize_scores.py` | 2.8 `#aggregation` | Open LLM Leaderboard chance normalisation (GPQA 46.67, MuSR 35.00), macro vs micro, multi-metric | `python3 code/ch02/normalize_scores.py` |
| `saturation_and_noise.py` | 2.9 `#noise`, Fig 2.6 | signal-to-noise for accuracy vs a continuous metric; the emergence mirage | `python3 code/ch02/saturation_and_noise.py` |
| `prompt_format_spread.py` | 2.10 `#prompt-sensitivity` | 20 formats, spread and rank swap; GSM8K strict vs flexible extraction; simple-evals MC regex | `python3 code/ch02/prompt_format_spread.py` |
| `contamination_demo.py` | 2.11 `#breakage` | 13-gram detector catches verbatim leaks, misses paraphrases; fresh twin set; label-noise ceiling | `python3 code/ch02/contamination_demo.py` |

Every script asserts the worked numbers quoted in the chapter, so a passing run means the text and the code agree.
