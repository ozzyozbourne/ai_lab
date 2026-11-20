# Chapter 5 code: Statistics and Rigor in Evals

Standard library + NumPy only (no SciPy). No network, no API keys; every model, judge and environment is a seeded mock.
Run any file from any directory, or all of them with `python3 code/run_all.py ch05`.
`_common.py` holds the normal CDF/quantile, binomial tails and the four one-sample intervals (Wald, Wilson,
Clopper-Pearson, Beta posterior); it is not run directly.

| File | Section | What it shows | Command |
|---|---|---|---|
| `error_bars.py` | 5.2 `#error-bars`, Fig 5.2 | 124/200 -> +/-6.7 pts; 12/30 -> +/-17.5 pts; 3/10 and 0/10 under four intervals; exact coverage for n in {30,100,300,1000}; Monte Carlo check; z vs t vs percentile vs BCa coverage for skewed non-binary scores at n = 20, 30 | `python3 code/ch05/error_bars.py` |
| `clustered.py` | 5.3 `#clustered` | 50 passages x 4 questions: naive vs clustered (Miller, Inspect) vs cluster-bootstrap SE (about 1.4x); CI coverage 83.5% vs 94.1% | `python3 code/ch05/clustered.py` |
| `resample_k.py` | 5.4 `#variance-reduction` | law of total variance; K in {1,4,16} shrinks only the within term; pooling K*n understates the SE; token-probability scoring | `python3 code/ch05/resample_k.py` |
| `paired.py` | 5.5 `#paired`, Fig 5.3 | unpaired vs paired SE, correlation identity, McNemar exact, sign-flip permutation, paired bootstrap, overlapping-CI fallacy; paired + clustered + K trials (40 repos x 5 tasks, K = 4): coverage 87.0% paired-only vs 94.7% clustered | `python3 code/ch05/paired.py` |
| `power.py` | 5.6 `#power`, Fig 5.4 | 4,361 / 2,181 / 873 questions for a 3-pt gain; Miller's 969; Monte Carlo power check; MDE table over n, rho, K | `python3 code/ch05/power.py` |
| `multiple_comparisons.py` | 5.7 `#multiple-comparisons` | 1-0.95^20 = 0.64; Bonferroni, Holm, BH (FWER, power, FDR); marginal vs simultaneous rank ranges; optional stopping (peeking after every seed: 28.3% false positives vs 5.0%) | `python3 code/ch05/multiple_comparisons.py` |
| `bootstrap_toolbox.py` | 5.8 `#bootstrap` | percentile/basic/BCa; bootstrap vs Wilson coverage at n=30; stratified bootstrap; seeding; replicate count | `python3 code/ch05/bootstrap_toolbox.py` |
| `passk.py` | 5.9 `#pass-hat-k`, Fig 5.5 | unbiased pass@k / pass^k vs Monte Carlo; Agent A vs Agent B; bias of (c/n)^k; Bayes@N credible interval; task-level SE, task and nested bootstrap CIs and coverage for pass^4 at n = 4, 8, 16 | `python3 code/ch05/passk.py` |
| `seeds_nondeterminism.py` | 5.10 `#nondeterminism` | batch-size-dependent greedy decoding, TARr@10 / TARa@10, batch-invariant run, seed sd on a 30-item set | `python3 code/ch05/seeds_nondeterminism.py` |
| `snr.py` | 5.11 `#snr` | signal, noise, SNR and decision accuracy for accuracy vs continuous metrics; monotonicity (Kendall tau) | `python3 code/ch05/snr.py` |
| `irt_tiny.py` | 5.12 `#irt`, Fig 5.6 | 2PL joint MLE in numpy; 50 random items vs 50 k-means anchors vs IRT ability fit; item characteristic curves | `python3 code/ch05/irt_tiny.py` |
| `rl_aggregates.py` | 5.13 `#rl-stats` | IQM worked example; mean/median/IQM/optimality gap with stratified bootstrap CIs; hand-written Mann-Whitney U; profiles | `python3 code/ch05/rl_aggregates.py` |
| `ppi_stats.py` | 5.14 `#ppi-stats` | judge-only (biased) vs human-only vs PPI intervals, coverage, the PPI gain vanishing for noisy judges, the Rogan-Gladen correction with a two-sample bootstrap CI, and power-tuned PPI++ (lambda*) falling back toward human-only | `python3 code/ch05/ppi_stats.py` |
| `hierarchical.py` | 5.15 `#bayes` | Beta-Binomial partial pooling on a (mu, kappa) grid for 8 task families; P(agent B > agent A) | `python3 code/ch05/hierarchical.py` |

Every script asserts the worked numbers quoted in the chapter, so a passing run means the text and the code agree.
The slowest file (`error_bars.py`, exact coverage up to n = 1000 plus the non-binary bootstrap coverage) takes about 25 s; the whole chapter runs in about 45 s.
