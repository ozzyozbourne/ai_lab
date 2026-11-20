# Research Dossier 05: Statistics and Rigor in Evals

*Prepared 2026-11-20 for the HTML book "Evaluations for AI: LLMs, Agents and RL Environments".*
*Every source in Section 3 was opened and checked: arXiv abstract pages (title, authors and date taken from the `citation_*` meta tags), arXiv HTML full text for the formulas, raw GitHub source files for the code, and GitHub search for star counts and last push date. Star counts are as of 2026-11-20.*

---

## 1. Overview: what this area is and how its parts fit together

An eval score is an **estimate**, not a fact. Think of a benchmark of *n* questions as a sample from a large, unseen "super-population" of questions that could have been written to test the same skill (Miller 2024, arXiv:2411.00640). For a stochastic model, each answer is also a random draw from that model's answer distribution. The reported number therefore has at least four independent sources of variation:

| Source of variance | What varies | Typical remedy |
|---|---|---|
| **Data (question-sampling) noise** | Which questions ended up in the benchmark | Standard errors, CIs, bigger or better-chosen benchmarks, IRT-based item selection |
| **Prediction (generation) noise** | Which answer the model samples for a given question (temperature, seed, non-determinism of the serving stack) | Resample K times per question, use token probabilities or continuous metrics, report mean ± sd over seeds |
| **Training noise** | Random seed of training or RL, checkpoint-to-checkpoint jitter | Multiple training runs, checkpoint averaging, rliable-style aggregates (IQM, stratified bootstrap) |
| **Setup / protocol noise** | Prompt template, few-shot examples, answer parser, harness, hardware, inference library | Multi-prompt evaluation, standardized harnesses, containerized stacks, full reporting |

The statistical toolkit stacks up in layers:

1. **Describe uncertainty for one model.** Use the standard error of the mean (CLT). For binary scores use the Bernoulli form, or Wilson or Bayesian intervals when *n* is small. When questions share a passage or task family, use clustered SEs. Bootstrap for non-mean metrics.
2. **Compare models.** Use paired differences on the same questions, McNemar or a paired permutation test, the paired bootstrap, and Bayesian paired models. Correct for multiple comparisons when there are many models or benchmarks.
3. **Plan experiments.** Use power analysis and minimum detectable effect (MDE) to choose the number of questions, the number of samples per question K, and the number of seeds.
4. **Agent and stochastic-system metrics.** pass@k (capability under k attempts) versus pass^k (reliability across k attempts), both with unbiased combinatorial estimators. Bayesian posteriors over success rate (Bayes@N).
5. **Benchmark-level quality.** Signal-to-noise ratio (AI2 *Signal and Noise*), seed variance and monotonicity (Madaan et al.), and decision accuracy.
6. **Psychometrics and efficient evaluation.** Item response theory (IRT), tinyBenchmarks, metabench, anchor points, Fluid Benchmarking (adaptive testing), PromptEval (distributions over prompts).
7. **RL evaluation statistics.** Few runs and many tasks. Agarwal et al. (2021) give IQM, performance profiles, probability of improvement, optimality gap and stratified bootstrap CIs (the `rliable` library). Henderson et al. (2017), Colas et al. (2018, 2019), Jordan et al. (2020) and Patterson et al. (2023) cover seeds, power and empirical design.
8. **Hierarchical and Bayesian modelling.** HiBayES (UK AISI) and the bayes_evals library (Bowyer et al.) handle nested and small-n agentic evals.
9. **Combining cheap automatic labels with scarce human labels.** Prediction-powered inference (PPI) and AutoEval Done Right give unbiased estimates with tighter intervals.
10. **Reporting.** Checklists from Dodge et al. (2019) "Show your work", Biderman et al. (2024) lm-eval lessons, Hochlehnert et al. (2025) "Sober look", and the Anthropic five recommendations.

The central idea that ties these together is the **law of total variance**:

Var(score) = E_q[Var(score | q)] + Var_q(E[score | q])

The first term is prediction noise. It shrinks with K samples per question. The second term is data noise. It shrinks only with more (or better) questions. Wang (2025, arXiv:2512.21326) measures both across many evals and finds that, in paired comparisons, **prediction noise usually exceeds data noise**. Averaging over multiple samples is therefore often the cheapest route to more statistical power.

---

## 2. Key concepts, formulas and worked examples

All numbers below were computed with a short Python script (stdlib only), so they can be reproduced in the chapter.

### 2.1 Standard error of the mean (CLT)

For per-question scores s_1..s_n with mean s̄:

- SE_CLT = sqrt( (1/(n-1)) Σ (s_i − s̄)² / n )
- Binary scores (Bernoulli): SE = sqrt( s̄(1 − s̄) / n )
- 95% CI = s̄ ± 1.96 · SE

(Formulas as given in Miller 2024, Sec. 2. Inspect's `stderr()` computes exactly `np.std(values, ddof=1)/np.sqrt(n)`.)

**Worked example.** 124/200 correct gives s̄ = 0.62, SE = sqrt(0.62·0.38/200) = 0.0343 and 95% CI = [0.553, 0.687]. That is ±6.7 points. Two models at 62% and 66% on this benchmark are not clearly different if you compare them unpaired.

**Small benchmark (AIME-style, n = 30).** 12/30 gives s̄ = 0.40 and SE = 0.089, so the 95% CI is about ±17.5 points. One question equals 3.3 points (Hochlehnert et al. 2025).

### 2.2 When the CLT fails: Wilson, Clopper–Pearson, Beta-Bernoulli

Bowyer, Aitchison and Ivanova (2025, arXiv:2503.01747, ICML 2025 position paper) show that CLT intervals under-cover when n is small. Even at N = 100, nominal 95% CLT intervals reach only about 92.5% coverage. Their recommendations:

- **Single model, IID questions:** use the Wilson score interval or a Beta-Bernoulli Bayesian credible interval with a uniform prior: posterior Beta(1 + k, 1 + n − k). Clopper–Pearson is valid but conservative.
- **Two independent models:** Bayesian intervals on the difference or odds ratio, computed by sampling both posteriors.
- **Paired models:** a paired Bayesian model that accounts for correlation.
- **Clustered questions:** a hierarchical Beta-Binomial model.
- **Non-average metrics (F1 etc.):** a Dirichlet posterior. The bootstrap and the delta-method CLT both under-cover here.

Wilson interval: centre = (p̂ + z²/2n)/(1 + z²/n); half-width = z·sqrt(p̂(1−p̂)/n + z²/4n²)/(1 + z²/n).

**Worked example (3/10 correct).** The Wald (CLT) interval is [0.016, 0.584]. The Wilson interval is [0.108, 0.603], which is asymmetric and stays inside [0, 1]. With 0/10 correct, Wald returns the degenerate [0, 0]. Wilson returns [0, 0.278].

### 2.3 Clustered standard errors

Questions often share a passage, a repository (SWE-bench), a task template, or an environment instance. They can also be the K resamples of the same question. Such questions are not independent. From Miller 2024, Eq. for clustered SE:

SE_clustered = ( SE_CLT² + (1/n²) Σ_c Σ_i Σ_{j≠i} (s_{i,c} − s̄)(s_{j,c} − s̄) )^{1/2}

This is equivalent to (1/n)·sqrt(Σ_c (Σ_{i∈c}(s_{i,c} − s̄))²). Inspect adds a finite-cluster correction factor C/(C − 1) (see code in Section 4).

**Worked example (simulated).** 50 passages × 4 questions, with each passage's difficulty drawn from {0.2, 0.5, 0.9}. Mean = 0.56. The naive SE is 0.0352 and the clustered SE is 0.0493, which is **1.40× larger**. Miller's point is that ignoring clustering underestimates uncertainty. The inflation factor depends on the eval (on the intra-cluster correlation and the cluster size), so don't quote a universal multiplier. *(I have not verified a specific real-eval multiplier from the paper.)*

### 2.4 Reducing within-question variance

- If each question is answered K times and the K scores are averaged, the conditional variance per question becomes σ_i²/K. The SE must then be computed on the per-question means, or clustered by question. Pooling all K·n answers as if independent is wrong (Miller 2024).
- For single-token answers (multiple choice), use the probability of the correct token, p_i, as the score. This removes generation noise entirely: Var(μ̂) = Var(p)/n.
- **Do not lower the temperature just to reduce variance.** Miller argues it can bias results or move variance into the conditional means. Hochlehnert et al. report that temperature 0 → 1 changes AIME scores by up to about 15 points, and top-p by up to about 8 points. Fix the sampling parameters per model and report them.
- Continuous metrics (log-prob, bits-per-byte) have higher SNR than accuracy for small models (Madaan et al. 2024; Heineman et al. 2025).

### 2.5 Paired differences

When models A and B answer the same questions, analyse d_i = s_{A,i} − s_{B,i}:

- SE_paired = sqrt( (1/(n−1)) Σ (d_i − d̄)² / n )
- Equivalent form: SE_paired = sqrt( SE_A² + SE_B² − 2·SE_A·SE_B·Corr(s_A, s_B) )

Models tend to agree on which questions are easy or hard, so their per-question scores are usually positively correlated and pairing cuts the variance a great deal. The exact correlations are eval-specific, so measure them and report them. Related tests:

- **McNemar's test** for binary outcomes. Only discordant pairs matter: b = A right and B wrong, c = A wrong and B right. χ² = (|b − c| − 1)²/(b + c), or use the exact binomial test on b out of (b + c).
- **Paired permutation (sign-flip) test.** Randomly flip the sign of each d_i and compare against the observed mean.
- **Paired bootstrap.** Resample question indices and recompute the difference (Koehn 2004 for MT; Berg-Kirkpatrick et al. 2012).

### 2.6 Power analysis and minimum detectable effect

From Miller 2024, with ω² = Var(x_A) + Var(x_B) − 2·Cov(x_A, x_B) and σ² the within-question variance:

n = (z_{α/2} + z_β)² · (ω² + σ_A²/K_A + σ_B²/K_B) / δ²

δ_MDE = (z_{α/2} + z_β) · sqrt( (ω² + σ_A²/K_A + σ_B²/K_B) / n )

**Worked example.** α = 0.05 two-sided (z = 1.96), power 80% (z = 0.8416), δ = 3 points, accuracy near 50% so Var = 0.25 each, ignoring σ² terms:

| Correlation between A and B | ω² | questions needed |
|---|---|---|
| 0 (unpaired / independent) | 0.50 | **4,361** |
| 0.5 | 0.25 | **2,181** |
| 0.8 | 0.10 | **873** |

Miller's own worked example reports about 969 questions for δ = 0.03 under its assumptions. The lesson for the chapter: most benchmarks with a few hundred items **cannot detect 1–3 point improvements**. Card et al. (2020) reach the same conclusion for NLP. Their example is that typical MT test sets of 2,000 sentences have about 75% power to detect a 1-BLEU difference, and many GLUE comparisons are underpowered.

### 2.7 Multiple comparisons

Testing 20 benchmarks at α = 0.05 with no true effect gives P(at least one "significant") = 1 − 0.95²⁰ = **0.64**. The fixes:

- **Bonferroni:** α/m = 0.0025.
- **Holm–Bonferroni** (step-down): uniformly more powerful than Bonferroni.
- **Benjamini–Hochberg:** controls the false discovery rate. This suits leaderboards with many model pairs.
- **Simultaneous confidence regions for rankings:** Chatbot Arena (Chiang et al. 2024) builds a joint χ²-based region from the sandwich covariance. It derives rank as 1 + #{models whose lower bound exceeds my upper bound}.
- **Pre-registration and held-out test sets.** Selecting the "best" prompt, checkpoint or seed on the test set inflates results. This is the benchmark-lottery problem (Dehghani et al. 2021) and part of the overfitting found by Hochlehnert et al. 2025.

### 2.8 Bootstrap confidence intervals

The nonparametric bootstrap works like this. Resample the n items with replacement B times (B ≥ 1,000; rliable's examples use 50,000). Recompute the statistic each time. Then take either the percentile interval [q_{2.5%}, q_{97.5%}], the basic or pivot interval, or the BCa interval (bias-corrected and accelerated). Variants:

- **Paired bootstrap:** resample question indices jointly for A and B.
- **Cluster bootstrap:** resample whole clusters. Inspect's `ci(method="bootstrap", cluster=...)` does this.
- **Stratified bootstrap** (rliable): resample runs independently within each task. Use it for multi-task RL with few runs per task.
- **Pitfalls:** the bootstrap of a mean is roughly equivalent to the CLT without Bessel's correction (noted in lm-eval's source comment). It under-covers at very small n (Bowyer et al.). It is the right tool for medians, F1, Elo/Bradley–Terry and IQM.

### 2.9 Variance from sampling temperature, seeds and serving non-determinism

- Atil et al. (2024, arXiv:2408.04667) ran five "deterministic" LLMs (temperature 0, fixed seed) over 10 runs. They saw accuracy variation of **up to 15%** across runs and a gap of up to 70% between best-possible and worst-possible. They define TARr@N (agreement on raw output strings) and TARa@N (agreement on parsed answers).
- Thinking Machines Lab, "Defeating Nondeterminism in LLM Inference" (Horace He et al., Sept 2025). The post argues that the main cause of temperature-0 non-determinism in served LLMs is the **lack of batch invariance**: results depend on batch size, which depends on server load. Concurrency plus floating-point non-associativity alone is not the explanation. Batch-invariant kernels (repo `thinking-machines-lab/batch_invariant_ops`) give bitwise-reproducible vLLM inference at some speed cost. *(Verified: partial. The post's title, authorship and the repo are confirmed. The details come from search snippets and secondary write-ups; the page was not fully read.)*
- Hochlehnert et al. (2025) found AIME'24 Pass@1 standard deviations across seeds of about 5–15 points. The same model on different clusters or GPUs differed by up to 8 points (OpenThinker2-7B: 53.0 on A100 vs 57.1 on H100). Switching eval frameworks changed one model by 4.5 points. They recommend averaging over many seeds (variance stabilizes near K ≈ 30 on AIME-sized sets).

### 2.10 pass@k vs pass^k

Both are defined per task, with n samples per task of which c are correct, and then averaged over tasks.

- **pass@k** (Chen et al. 2021, arXiv:2107.03374) is the probability that *at least one* of k samples is correct. Unbiased estimator: 1 − C(n − c, k)/C(n, k). The naive plug-in 1 − (1 − ĉ/n)^k is biased.
- **pass^k** (Yao et al. 2024, τ-bench, arXiv:2406.12045) is the probability that *all* k i.i.d. trials succeed. Estimator: C(c, k)/C(n, k). This measures reliability or consistency, which matters for agents deployed to many users. In τ-bench, gpt-4o's pass^1 is about 61% on retail, but pass^8 is below 25%.

**Worked example (single task, n = 10, c = 3).** pass@5 = 1 − C(7,5)/C(10,5) = 1 − 21/252 = 0.917. pass^2 = C(3,2)/C(10,2) = 3/45 = 0.067 (the naive estimate 0.3² = 0.09 is biased upward). pass^5 = 0.

**Worked example: two agents with the same pass@1 = 0.6 over 10 tasks.**
Agent A succeeds 60% of the time on every task. Agent B always solves 6 tasks and never solves the other 4.

| k | pass^k A | pass^k B | pass@k A | pass@k B |
|---|---|---|---|---|
| 1 | 0.60 | 0.60 | 0.60 | 0.60 |
| 2 | 0.36 | 0.60 | 0.84 | 0.60 |
| 4 | 0.13 | 0.60 | 0.97 | 0.60 |
| 8 | 0.017 | 0.60 | 0.999 | 0.60 |

The same mean score hides very different behaviour. pass@k rewards diversity; pass^k rewards consistency. Report both, or report the per-task success-rate distribution.

**Bayesian alternative.** Hariri et al. (2025, arXiv:2510.04265, ICLR 2026) propose "Bayes@N". They model outcomes as categorical with a Dirichlet prior (Beta for binary outcomes) and report the posterior mean of success probability with credible intervals. Under a uniform prior, the posterior mean ranks models the same way as avg@N/Pass@1, and it converges faster and gives more stable rankings than pass@k on AIME/HMMT. Code: `mohsenhariri/scorio`.

### 2.11 Item response theory (IRT) for benchmarks

The 2PL model gives P(model l answers item i correctly) = σ(a_i(θ_l − b_i)), where θ is ability, b is difficulty and a is discrimination. The multidimensional version used by tinyBenchmarks is p_il = 1/(1 + exp(−α_iᵀθ_l + β_i)).

- **tinyBenchmarks** (Maia Polo et al. 2024, arXiv:2402.14992). About 100 curated items are enough to estimate MMLU accuracy within about 2% average error. Anchor points are chosen by K-Means over correctness vectors or over IRT embeddings. Estimators: IRT, p-IRT and gp-IRT (a convex combination of the direct estimate and the IRT estimate).
- **metabench** (Kipnis et al. 2024, arXiv:2407.12844). Uses more than 5,000 LLMs to distil six Open-LLM-Leaderboard benchmarks (28,632 items) to under 3% of their size. It reconstructs the original scores with 1.24% RMSE per benchmark and 0.58% for the total.
- **Anchor Points** (Vivek et al. 2023, arXiv:2309.08638). Just 1–30 points can rank models across 87 model-prompt pairs.
- **Fluid Benchmarking** (Hofmann et al., AI2, 2025, arXiv:2509.11106). Computerized adaptive testing. It picks items dynamically according to the ability estimate. On MMLU it reports higher validity and lower variance with 50× fewer items.
- **Rodriguez et al. 2021** (ACL, "Evaluation Examples are not Equally Informative"). IRT-based leaderboards (DAD) that estimate difficulty and discriminability and flag annotation errors.
- **Lalor et al. 2016** (arXiv:1605.08889). An early application of IRT to building NLP eval scales.
- **Counterpoint.** Madaan et al. (2024) found that IRT-selected subsets *increased* seed variance during pretraining. ARC-C seed std rose from 0.80 to 1.80 and HellaSwag from 0.21 to 2.06. IRT helps with estimating final-model scores cheaply, not necessarily with tracking small training-time differences.

### 2.12 Benchmark signal and noise (AI2)

Heineman et al. (2025, arXiv:2508.13144):

- **Signal** = relative dispersion = max_{j,k} |m_j − m_k| / m̄, computed across models at similar compute.
- **Noise** = relative std of a single model's final n checkpoints.
- **SNR** = signal / noise.
- **Decision accuracy** = the fraction of model pairs where the small-scale ranking matches the large-scale ranking (equivalent to Kendall's τ via τ = 2·DA − 1).

Findings: SNR correlates with decision accuracy (R = 0.791), while signal or noise alone barely does. The analysis covers 465 models and 30 benchmarks. Three interventions raise SNR: filtering subtasks by SNR (MMLU decision accuracy +2.6%), averaging checkpoints (+2.4%), and using bits-per-byte instead of accuracy (decision accuracy improved on 90% of benchmarks).

Madaan et al. (2024, arXiv:2406.10229) supply complementary metrics: seed std, bootstrap 95% CI and monotonicity (the Kendall correlation of a score with training progress). Table 1 for 7B models across 10 seeds: MMLU seed std 0.57 vs CI 0.72; ARC-C 0.80 vs 2.74; HellaSwag 0.21 vs 0.93. MMLU-Cloze has monotonicity 0.95 vs 0.09 for standard MMLU early in training.

### 2.13 RL evaluation statistics

Agarwal et al. (2021, arXiv:2108.13264, NeurIPS 2021 Outstanding Paper):

- Most deep-RL papers use 3–10 runs per task. Point estimates of the mean or median are then unreliable and biased. For SPR on Atari 100k, going from 5 to 100 runs shifts the median by +0.03, which is about 36% of its claimed improvement.
- **IQM** (interquartile mean) is the 25% trimmed mean over all runs × tasks. It is robust to outliers like the median, but uses more of the data and so gives tighter CIs. *Example:* scores [0, .1, .2, .3, .35, .4, .45, .5, 3.0, 9.0] have mean 1.43, median 0.375 and IQM 0.367 (via `scipy.stats.trim_mean(x, 0.25)`). The two outlier tasks dominate the mean.
- **Performance profiles (score distributions):** the fraction of runs with normalized score above τ, plotted with CI bands. Like a survival function.
- **Probability of improvement:** P(X > Y) per task via the Mann–Whitney U statistic, averaged over tasks.
- **Optimality gap:** γ − mean(min(score, γ)).
- **Stratified bootstrap CIs:** resample runs within each task.
- They recommend against dichotomous significance tests. Report intervals, keep protocols fixed, and release per-run scores.

Earlier and complementary work:

- Henderson et al. 2017 (arXiv:1709.06560, "Deep RL that Matters") showed that seeds, codebases and hyperparameters change conclusions. They also show that two sets of seeds of the *same* algorithm can produce learning curves that look significantly different. *(This specific figure is from prior knowledge, so check the details before quoting.)*
- Colas et al. 2018 (arXiv:1806.08295) cover power analysis for choosing the number of seeds; Colas et al. 2019 (arXiv:1904.06979) compare tests (Welch t-test, bootstrap, permutation, Mann–Whitney) and their false-positive rates under non-normal returns.
- Jordan et al. 2020 (arXiv:2006.16958) propose performance-percentile aggregation across environments with confidence intervals.
- Patterson et al. 2023 (arXiv:2304.01315, "Empirical Design in RL") is a long practitioner guide to seeds, hyperparameters, CIs and common errors.

The same ideas transfer to **RL environments for LLM agents**. Treat each environment or task as a "task", each rollout seed as a "run", and use IQM with stratified bootstrap over rollouts.

### 2.14 Combining LLM-judge labels with human labels: PPI

Prediction-powered inference (Angelopoulos et al. 2023, arXiv:2301.09633) gives an estimate of mean quality θ from a large set of N items scored by an automatic judge f and a small set of n items with human labels Y:

θ̂_PPI = (1/N) Σ f(X̃_j) + (1/n) Σ (Y_i − f(X_i))

The second term is the "rectifier". The estimator is unbiased even if the judge is biased, and its CI is narrower than one from human labels alone when the judge is accurate. Boyeau et al. (2024, arXiv:2403.07008, AutoEval Done Right) apply this to model evaluation and increase the effective human sample size by up to 50% with GPT-4 judges. Library: `aangelopoulos/ppi_py`.

### 2.15 Hierarchical Bayesian models

HiBayES (Luettgau et al., UK AISI, 2025, arXiv:2505.05602) uses multilevel Bayesian GLMs for nested eval data: responses within items within categories within models. It handles low-data regimes (fewer than 20 data points per eval, typical for agentic evals) and compares models formally. Package: `UKGovernmentBEIS/hibayes`. A simple teaching analogue is a Beta-Binomial hierarchy fitted with a grid or with importance sampling (as in bayes_evals).

---

## 3. Annotated source list (validated)

The verified tag means: **yes** = I opened the abstract or full page and confirmed the title, authors, year, URL and the attributed claim; **partial** = title and existence confirmed, some details from secondary sources.

### Papers

1. **Miller, E. (2024). "Adding Error Bars to Evals: A Statistical Approach to Language Model Evaluations."** arXiv:2411.00640 (Anthropic). https://arxiv.org/abs/2411.00640
   Treats eval questions as draws from a super-population. Gives the CLT SE, clustered SE, variance reduction via resampling and next-token probabilities, paired-difference SE with a correlation term, and power and sample-size formulas. It is the main formula source for Sections 2.1–2.6, and Inspect's clustered SE cites its Appendix A. *verified: yes*

2. **Anthropic (2024-11-19). "A statistical approach to model evaluations."** https://www.anthropic.com/research/statistical-approach-to-model-evals
   The blog companion to Miller (2024), with the five recommendations: CLT SEs, clustered SEs, reducing within-question variance, paired differences and power analysis. A good intro framing for the chapter. *verified: yes*

3. **Agarwal, R., Schwarzer, M., Castro, P. S., Courville, A., Bellemare, M. (2021). "Deep Reinforcement Learning at the Edge of the Statistical Precipice."** arXiv:2108.13264, NeurIPS 2021 Outstanding Paper. https://arxiv.org/abs/2108.13264
   Shows that few-run point estimates mislead (case study on Atari 100k). Proposes stratified bootstrap CIs, performance profiles, IQM, optimality gap and probability of improvement, and releases rliable. *verified: yes*

4. **Heineman, D., Hofmann, V., Magnusson, I., et al. (AI2, 2025). "Signal and Noise: A Framework for Reducing Uncertainty in Language Model Evaluation."** arXiv:2508.13144. https://arxiv.org/abs/2508.13144
   Defines signal (relative dispersion), noise (relative std across final checkpoints), SNR and decision accuracy. Shows that SNR predicts small-to-large decision accuracy (R = 0.791). Three interventions: subtask filtering, checkpoint averaging and BPB metrics. Repo: allenai/signal-and-noise. *verified: yes*

5. **Madaan, L., Singh, A. K., Schaeffer, R., et al. (Meta, 2024). "Quantifying Variance in Evaluation Benchmarks."** arXiv:2406.10229. https://arxiv.org/abs/2406.10229
   Measures seed variance (10 seeds, 7B models), bootstrap CIs and monotonicity across benchmarks. Recommends continuous metrics and cloze formats for small models. Finds that IRT and item analysis do not reduce variance. *verified: yes*

6. **Bowyer, S., Aitchison, L., Ivanova, D. R. (2025). "Position: Don't Use the CLT in LLM Evals With Fewer Than a Few Hundred Datapoints."** arXiv:2503.01747, ICML 2025. https://arxiv.org/abs/2503.01747
   Simulations show that CLT intervals under-cover at small N (about 92.5% at N = 100 for a nominal 95%). Recommends Wilson or Beta-Bernoulli intervals, paired Bayes and hierarchical Beta-Binomial models for clustered data. Library: sambowyer/bayes_evals. *verified: yes*

7. **Chen, M., Tworek, J., Jun, H., et al. (OpenAI, 2021). "Evaluating Large Language Models Trained on Code."** arXiv:2107.03374. https://arxiv.org/abs/2107.03374
   Introduces HumanEval and the unbiased pass@k estimator 1 − C(n − c, k)/C(n, k), with a numerically stable implementation in openai/human-eval. *verified: yes*

8. **Yao, S., Shinn, N., Razavi, P., Narasimhan, K. (Sierra, 2024). "τ-bench: A Benchmark for Tool-Agent-User Interaction in Real-World Domains."** arXiv:2406.12045. https://arxiv.org/abs/2406.12045
   Defines pass^k = E_task[C(c, k)/C(n, k)] for agent reliability. gpt-4o is about 61% pass^1 on retail but below 25% pass^8. *verified: yes*

9. **Hariri, M., Samandar, A., Hinczewski, M., Chaudhary, V. (2025). "Don't Pass@k: A Bayesian Framework for Large Language Model Evaluation."** arXiv:2510.04265, ICLR 2026. https://arxiv.org/abs/2510.04265
   A Dirichlet or Beta posterior over success probability with credible intervals. Under a uniform prior it is order-equivalent to Pass@1, and it gives more stable rankings than pass@k at small N. Code: mohsenhariri/scorio. *verified: yes*

10. **Maia Polo, F., Weber, L., Choshen, L., Sun, Y., Xu, G., Yurochkin, M. (2024). "tinyBenchmarks: evaluating LLMs with fewer examples."** arXiv:2402.14992, ICML 2024. https://arxiv.org/abs/2402.14992
    Multidimensional 2PL IRT, anchor-point selection, and the p-IRT and gp-IRT estimators. 100 MMLU items give about 2% estimation error. *verified: yes*

11. **Maia Polo, F., Xu, R., Weber, L., et al. (2024). "Efficient multi-prompt evaluation of LLMs" (PromptEval).** arXiv:2405.17202. https://arxiv.org/abs/2405.17202
    Estimates the full distribution of performance across 100 prompt templates for the budget of about two single-prompt evaluations. Enables quantile metrics such as the median or the 95th percentile over prompts. *verified: yes*

12. **Kipnis, A., Voudouris, K., Schulze Buschoff, L. M., Schulz, E. (2024). "metabench — A Sparse Benchmark of Reasoning and Knowledge in Large Language Models."** arXiv:2407.12844. https://arxiv.org/abs/2407.12844
    Uses IRT on more than 5,000 LLMs to compress six benchmarks (28,632 items) to under 3% of their size, with 1.24% RMSE in reconstructing scores. *verified: yes*

13. **Vivek, R., Ethayarajh, K., Yang, D., Kiela, D. (2023). "Anchor Points: Benchmarking Models with Much Fewer Examples."** arXiv:2309.08638. https://arxiv.org/abs/2309.08638
    Model confidence is correlated across examples, so 1–30 anchor points can rank 87 model-prompt pairs better than uniform sampling. *verified: yes*

14. **Hofmann, V., Heineman, D., Magnusson, I., et al. (AI2, 2025). "Fluid Language Model Benchmarking."** arXiv:2509.11106. https://arxiv.org/abs/2509.11106
    IRT plus adaptive item selection (computerized adaptive testing). Improves efficiency, validity, variance and saturation, with 50× fewer MMLU items. Repo: allenai/fluid-benchmarking. *verified: yes*

15. **Hochlehnert, A., Bhatnagar, H., Udandarao, V., Albanie, S., Prabhu, A., Bethge, M. (2025). "A Sober Look at Progress in Language Model Reasoning: Pitfalls and Paths to Reproducibility."** arXiv:2504.07086. https://arxiv.org/abs/2504.07086
    Seed std of 5–15 points on AIME'24, hardware and framework effects of up to 8 points, and the sensitivity of results to temperature and top-p. Concludes that many RL reasoning gains shrink under rigorous evaluation. Gives reporting best practices. *verified: yes*

16. **Biderman, S., Schoelkopf, H., Sutawika, L., et al. (EleutherAI, 2024). "Lessons from the Trenches on Reproducible Evaluation of Language Models."** arXiv:2405.14782. https://arxiv.org/abs/2405.14782
    Three years of lm-eval-harness experience: setup sensitivity, comparison pitfalls and reporting recommendations, including reporting standard errors. *verified: yes*

17. **Chiang, W.-L., Zheng, L., Sheng, Y., et al. (LMSYS, 2024). "Chatbot Arena: An Open Platform for Evaluating LLMs by Human Preference."** arXiv:2403.04132. https://arxiv.org/abs/2403.04132
    Bradley–Terry with inverse-probability weighting, sandwich-robust SEs versus the pivot bootstrap, simultaneous CIs for rank, and active sampling that targets CI-width reduction. *verified: yes*

18. **Card, D., Henderson, P., Khandelwal, U., Jia, R., Mahowald, K., Jurafsky, D. (2020). "With Little Power Comes Great Responsibility."** arXiv:2010.06595, EMNLP 2020 (aclanthology 2020.emnlp-main.745). https://arxiv.org/abs/2010.06595
    Power is ignored in NLP, and many GLUE comparisons and human-rating studies are underpowered. 2,000-sentence MT test sets have about 75% power for a 1-BLEU difference. Releases power-analysis notebooks. *verified: yes*

19. **Dror, R., Baumer, G., Shlomov, S., Reichart, R. (2018). "The Hitchhiker's Guide to Testing Statistical Significance in Natural Language Processing."** ACL 2018. https://aclanthology.org/P18-1128/
    A survey and decision tree for choosing significance tests (parametric vs nonparametric, bootstrap, permutation) for NLP metrics. *verified: partial (title, venue and URL confirmed; content from prior knowledge)*

20. **Berg-Kirkpatrick, T., Burkett, D., Klein, D. (2012). "An Empirical Investigation of Statistical Significance in NLP."** EMNLP 2012. https://aclanthology.org/D12-1091/
    Examines the paired bootstrap and how often significance at a given metric gap holds across test sets. A classic for paired bootstrap rules of thumb. *verified: partial (title and URL confirmed)*

21. **Koehn, P. (2004). "Statistical Significance Tests for Machine Translation Evaluation."** EMNLP 2004. https://aclanthology.org/W04-3250/
    Introduced bootstrap resampling and paired bootstrap for BLEU. The origin of the "paired bootstrap" test in NLP. *verified: partial (title and URL confirmed)*

22. **Dodge, J., Gururangan, S., Card, D., Schwartz, R., Smith, N. A. (2019). "Show Your Work: Improved Reporting of Experimental Results."** arXiv:1909.03004, EMNLP 2019. https://arxiv.org/abs/1909.03004
    Expected validation performance as a function of hyperparameter-search budget, plus a reproducibility checklist. *verified: yes (title and authors); claims from prior knowledge*

23. **Reimers, N., Gurevych, I. (2017). "Reporting Score Distributions Makes a Difference."** arXiv:1707.09861. https://arxiv.org/abs/1707.09861
    Seed-only changes produce statistically significant differences for LSTM taggers, so report score distributions over seeds, not single runs. *verified: yes (title and authors)*

24. **Bouthillier, X., Delaunay, P., Bronzi, M., et al. (2021). "Accounting for Variance in Machine Learning Benchmarks."** arXiv:2103.03098, MLSys 2021. https://arxiv.org/abs/2103.03098
    Models variance from data sampling, initialization and hyperparameters. Randomizing more sources of variation gets 51× cheaper toward the ideal estimator. Recommendations for comparisons, including the probability of outperforming. *verified: yes*

25. **Ulmer, D., Hardmeier, C., Frellsen, J. (2022). "deep-significance: Easy and Meaningful Statistical Significance Testing in the Age of Neural Networks."** arXiv:2204.06815. https://arxiv.org/abs/2204.06815
    A library implementing Almost Stochastic Order (ASO, from Dror et al. 2019 "Deep Dominance", ACL P19-1266), bootstrap and permutation tests, and Bonferroni correction. *verified: yes (paper and repo); ASO paper title confirmed on ACL Anthology*

26. **Henderson, P., Islam, R., Bachman, P., Pineau, J., Precup, D., Meger, D. (2017). "Deep Reinforcement Learning that Matters."** arXiv:1709.06560, AAAI 2018. https://arxiv.org/abs/1709.06560
    Seeds, implementations and environment settings change RL conclusions. Calls for significance testing and many seeds. *verified: yes (title and authors)*

27. **Colas, C., Sigaud, O., Oudeyer, P.-Y. (2018). "How Many Random Seeds? Statistical Power Analysis in Deep RL Experiments."** arXiv:1806.08295; **(2019) "A Hitchhiker's Guide to Statistical Comparisons of RL Algorithms."** arXiv:1904.06979.
    Power analysis for seed counts, and an empirical comparison of the false-positive rates of statistical tests on RL returns. *verified: yes (titles and authors)*

28. **Jordan, S. M., Chandak, Y., Cohen, D., Zhang, M., Thomas, P. S. (2020). "Evaluating the Performance of Reinforcement Learning Algorithms."** arXiv:2006.16958, ICML 2020. https://arxiv.org/abs/2006.16958
    Argues that inconsistency stems from flawed metrics. Proposes a comprehensive methodology that aggregates across environments with reliable CIs. *verified: yes*

29. **Patterson, A., Neumann, S., White, M., White, A. (2023). "Empirical Design in Reinforcement Learning."** arXiv:2304.01315. https://arxiv.org/abs/2304.01315
    A long practical guide to running statistically sound RL experiments. *verified: yes (title and authors)*

30. **Angelopoulos, A. N., Bates, S., Fannjiang, C., Jordan, M. I., Zrnic, T. (2023). "Prediction-Powered Inference."** arXiv:2301.09633, Science 2023. https://arxiv.org/abs/2301.09633
    Valid CIs that combine ML predictions with a small gold-labelled set via a rectifier. *verified: yes (title and authors)*

31. **Boyeau, P., Angelopoulos, A. N., Yosef, N., Malik, J., Jordan, M. I. (2024). "AutoEval Done Right: Using Synthetic Data for Model Evaluation."** arXiv:2403.07008. https://arxiv.org/abs/2403.07008
    PPI for model evaluation with LLM judges. Up to 50% larger effective human sample size with GPT-4. *verified: yes*

32. **Atil, B., Aykent, S., Chittams, A., et al. (2024). "Non-Determinism of 'Deterministic' LLM Settings."** arXiv:2408.04667. https://arxiv.org/abs/2408.04667
    Five LLMs, eight tasks, 10 runs at "deterministic" settings: up to 15% accuracy variation. Introduces TARr@N and TARa@N. *verified: yes*

33. **Mizrahi, M., Kaplan, G., Malkin, D., Dror, R., Shahaf, D., Stanovsky, G. (2024). "State of What Art? A Call for Multi-Prompt LLM Evaluation."** arXiv:2401.00595, TACL. https://arxiv.org/abs/2401.00595
    6.5M instances, 20 LLMs, 39 tasks. Single-prompt results are brittle. Proposes multi-prompt metrics. *verified: yes*

34. **Sclar, M., Choi, Y., Tsvetkov, Y., Suhr, A. (2023). "Quantifying Language Models' Sensitivity to Spurious Features in Prompt Design."** arXiv:2310.11324, ICLR 2024. https://arxiv.org/abs/2310.11324
    Formatting changes alone can swing accuracy by large margins. Proposes FormatSpread to report a range over formats. *verified: yes (title and authors); magnitude claims from prior knowledge, so cite them cautiously*

35. **Dehghani, M., Tay, Y., Gritsenko, A. A., et al. (2021). "The Benchmark Lottery."** arXiv:2107.07002. https://arxiv.org/abs/2107.07002
    The choice of benchmarks and aggregation decides "SOTA". A meta-point about multiple comparisons and selection effects. *verified: yes (title and authors)*

36. **Luettgau, L., Coppock, H., Dubois, M., Summerfield, C., Ududec, C. (UK AISI, 2025). "HiBayES: A Hierarchical Bayesian Modeling Framework for AI Evaluation Statistics."** arXiv:2505.05602. https://arxiv.org/abs/2505.05602
    Multilevel Bayesian GLMs for nested, low-data agentic evals (fewer than 20 points per eval). Package: UKGovernmentBEIS/hibayes. *verified: yes*

37. **Wang, S. I. (FAIR at Meta, 2025). "Measuring all the noises of LLM Evals."** arXiv:2512.21326. https://arxiv.org/abs/2512.21326
    Splits noise into prediction, data and total (law of total variance). All-pairs paired comparisons across many evals: each eval has a characteristic total noise level, and paired prediction noise usually exceeds data noise. Code: all-the-noises/eval-arena. *verified: yes (abstract); the "MATH500 prediction SE ≈ 2× data SE" detail is from search summaries, so it is partial*

38. **Rodriguez, P., Barrow, J., Hoyle, A. M., Lalor, J. P., Jia, R., Boyd-Graber, J. (2021). "Evaluation Examples are not Equally Informative: How should that change NLP Leaderboards?"** ACL 2021. https://aclanthology.org/2021.acl-long.346/
    An IRT-based leaderboard that models difficulty and discriminability of examples. *verified: partial (title and URL)*

39. **Lalor, J. P., Wu, H., Yu, H. (2016). "Building an Evaluation Scale using Item Response Theory."** arXiv:1605.08889. https://arxiv.org/abs/1605.08889. *verified: yes (title and authors)*

### Repositories (stars and last push as of 2026-11-20, from the GitHub search API)

40. **google-research/rliable.** https://github.com/google-research/rliable (876 stars; last push 2024-08-12). The reference implementation of IQM, optimality gap, probability of improvement, stratified bootstrap (`StratifiedBootstrap`, built on `arch`) and performance profiles. *verified: yes (source read)*
41. **UKGovernmentBEIS/inspect_ai.** https://github.com/UKGovernmentBEIS/inspect_ai (3,293 stars; pushed 2026-11-20). `stderr(cluster=...)`, `bootstrap_stderr`, and `ci(method="t"|"bootstrap", cluster=...)` with cluster bootstrap. *verified: yes (source read: `src/inspect_ai/scorer/_metrics/std.py`)*
42. **EleutherAI/lm-evaluation-harness.** https://github.com/EleutherAI/lm-evaluation-harness (14,504 stars; pushed 2026-11-04). `mean_stderr`, `bootstrap_stderr`, `pooled_sample_stderr` for task groups, and the `--bootstrap_iters` flag. *verified: yes (source read: `lm_eval/api/metrics.py`)*
43. **openai/simple-evals.** https://github.com/openai/simple-evals (4,710 stars; pushed 2026-04-22). The `_compute_stat(..., "bootstrap_std")` 1,000-resample bootstrap in `common.py`. *verified: yes*
44. **openai/human-eval.** https://github.com/openai/human-eval (3,431 stars). `estimate_pass_at_k`, the numerically stable unbiased estimator. *verified: yes*
45. **sierra-research/tau-bench** (1,514 stars) and **sierra-research/tau2-bench** (2,487 stars; pushed 2026-11-10). pass^k reporting for agent reliability. *verified: yes (existence and stars)*
46. **felipemaiapolo/tinyBenchmarks.** https://github.com/felipemaiapolo/tinyBenchmarks (188 stars; pushed 2026-07-04). *verified: yes*
47. **sambowyer/bayes_evals.** https://github.com/sambowyer/bayes_evals (25 stars; pushed 2025-05-28). Bayesian intervals for small evals. *verified: yes*
48. **mohsenhariri/scorio.** https://github.com/mohsenhariri/scorio (24 stars; pushed 2026-11-09). Bayes@N and ranking. *verified: yes*
49. **Kaleidophon/deep-significance.** https://github.com/Kaleidophon/deep-significance (343 stars; pushed 2026-09-21). ASO, bootstrap and permutation tests, Bonferroni. *verified: yes*
50. **aangelopoulos/ppi_py.** https://github.com/aangelopoulos/ppi_py (310 stars; pushed 2026-04-10). *verified: yes*
51. **allenai/signal-and-noise** (32 stars) and **allenai/fluid-benchmarking** (29 stars). *verified: yes*
52. **UKGovernmentBEIS/hibayes** (60 stars; pushed 2026-11-13) and **all-the-noises/eval-arena** (34 stars). *verified: yes*
53. **thinking-machines-lab/batch_invariant_ops** (1,092 stars; pushed 2025-11-04). Batch-invariant kernels for deterministic inference. *verified: yes (repo); blog details partial*
54. **Comcast/llm-stability** (9 stars). Code for Atil et al. 2024 (the paper's abstract names breckbaldwin/llm-stability; the search finds it under the Comcast org). *verified: partial*

### Articles

55. **Thinking Machines Lab (Horace He et al., Sept 2025). "Defeating Nondeterminism in LLM Inference."** https://thinkingmachines.ai/blog/defeating-nondeterminism-in-llm-inference/ Argues batch invariance, not just floating-point concurrency, is the cause. *verified: partial*
56. **UK AISI blog. "HiBayES: improving LLM evaluation with hierarchical Bayesian modelling."** https://www.aisi.gov.uk/blog/hibayes-improving-llm-evaluation-with-hierarchical-bayesian-modelling *verified: partial (found in search, not opened)*

**Count:** 44 sources are fully verified (yes); about 10 are partially verified.

---

## 4. Code patterns from real repos

### 4.1 Unbiased pass@k (openai/human-eval, `human_eval/evaluation.py`)

```python
def estimator(n: int, c: int, k: int) -> float:
    """
    Calculates 1 - comb(n - c, k) / comb(n, k).
    """
    if n - c < k:
        return 1.0
    return 1.0 - np.prod(1.0 - k / np.arange(n - c + 1, n + 1))
```

The product form avoids overflow in large binomial coefficients. For teaching, add pass^k as `comb(c, k) / comb(n, k)` using `math.comb`.

### 4.2 CLT and clustered SE (UKGovernmentBEIS/inspect_ai, `src/inspect_ai/scorer/_metrics/std.py`)

```python
def _clustered_stderr(partition: list[list[float]]) -> float:
    """Clustered standard error of the mean over a cluster partition.

    For details, see Appendix A of https://arxiv.org/pdf/2411.00640.
    The version here uses a finite cluster correction (unlike the paper)
    """
    ...
    clustered_variance = 0.0
    for cluster_data in cluster_arrays:
        clustered_variance += ((cluster_data - mean).sum()) ** 2
    # Multiply by C / (C - 1) to unbias the variance estimate
    standard_error = np.sqrt(
        clustered_variance * cluster_count / (cluster_count - 1)
    ) / len(values)
```

The non-clustered path is `np.std(values, ddof=1) / np.sqrt(n)`. In a task you use it as `metrics=[mean(), stderr(cluster="passage_id")]`, or with `ci(method="bootstrap", cluster=...)`, which resamples whole clusters.

### 4.3 Bootstrap stderr (EleutherAI/lm-evaluation-harness, `lm_eval/api/metrics.py`)

```python
def mean_stderr(arr):
    return sample_stddev(arr) / math.sqrt(len(arr))

def _bootstrap_internal_no_mp(f, xs, iters):
    res = []
    chunk_size = min(1000, iters)
    for i in tqdm(range(iters // chunk_size)):
        rnd = random.Random(i)
        for _ in range(chunk_size):
            res.append(f(rnd.choices(xs, k=len(xs))))
```

The code carries an honest comment that the bootstrap "gives a biased estimate of the stderr (i.e w/ the mean, it gives something equivalent to stderr calculated without Bessel's correction)". It also includes `pooled_sample_stderr` for task groups, and a `combined_sample_stderr` marked "don't use this unless a statistician has told you it's the right thing to do". Both are good teaching material on aggregation.

### 4.4 Bootstrap std (openai/simple-evals, `common.py`)

```python
elif stat == "bootstrap_std":
    return np.std(
        [np.mean(np.random.choice(values, len(values))) for _ in range(1000)]
    )
```

This minimal bootstrap is unseeded, so it is not reproducible. That makes it a pitfall worth pointing out: always seed your RNG.

### 4.5 rliable aggregates (google-research/rliable, `rliable/metrics.py`, README)

```python
def aggregate_iqm(scores: np.ndarray):
  return scipy.stats.trim_mean(scores, proportiontocut=0.25, axis=None)

def aggregate_optimality_gap(scores: np.ndarray, gamma=1):
  return gamma - np.mean(np.minimum(scores, gamma))

# probability_of_improvement uses scipy.stats.mannwhitneyu(..., alternative='greater')
# divided by (num_runs_x * num_runs_y), averaged over tasks.
```

README usage:

```python
aggregate_func = lambda x: np.array([
  metrics.aggregate_median(x), metrics.aggregate_iqm(x),
  metrics.aggregate_mean(x), metrics.aggregate_optimality_gap(x)])
aggregate_scores, aggregate_score_cis = rly.get_interval_estimates(
  atari_200m_normalized_score_dict, aggregate_func, reps=50000)
```

Scores are arrays of shape `(num_runs, num_tasks)`. `get_interval_estimates` supports `percentile`, `basic`, `bc` and `bca` methods through `StratifiedBootstrap`.

### 4.6 Ideas for self-contained teaching examples (stdlib or numpy, mocked models, no API keys)

1. **`error_bars.py`:** simulate a mock model with true accuracy 0.65 on n ∈ {30, 100, 300, 1000} questions. Compute Wald, Wilson and Beta-posterior intervals. Run 10,000 simulations and print empirical coverage, which reproduces Bowyer et al.'s finding that Wald under-covers at small n.
2. **`clustered.py`:** build passages with latent difficulty and several questions each. Compare the naive SE, the clustered SE (Inspect formula) and the cluster bootstrap. Show that the naive 95% CIs cover only about 80–85% of the time.
3. **`paired.py`:** two mock models that share item difficulty (a latent θ_i plus model effect plus noise). Compare the unpaired SE of the difference with the paired SE, McNemar's exact test and a paired permutation test. Show how the correlation term shrinks the SE.
4. **`power.py`:** implement Miller's n formula and the MDE. Plot (as ASCII or a printed table) MDE against n for correlation ∈ {0, 0.5, 0.8} and K ∈ {1, 4, 16}. Validate by simulation: the empirical rejection rate should come out near 80%.
5. **`resample_k.py`:** a mock stochastic model with per-question success probability p_i ~ Beta(a, b). Show the variance decomposition (law of total variance). Show that averaging K samples reduces only the within-question term, and that pooling K·n samples wrongly shrinks the SE (versus clustering by question).
6. **`passk.py`:** implement pass@k and pass^k with `math.comb` and check them against Monte Carlo. Reproduce the "Agent A vs Agent B" table from Section 2.10. Show that the naive (ĉ/n)^k estimator is biased.
7. **`multiple_comparisons.py`:** 20 benchmarks with no true difference. Count false positives under no correction, Bonferroni, Holm and Benjamini–Hochberg (implement BH in about 10 lines).
8. **`rl_aggregates.py`:** a mock (runs × tasks) score matrix with heavy-tailed noise. Implement IQM, optimality gap, probability of improvement (via the U statistic, written by hand) and a stratified bootstrap CI in pure numpy. Show the instability of the median with 3 vs 10 runs.
9. **`irt_tiny.py`:** simulate 200 mock models with a 2PL IRT model on 1,000 items. Fit item parameters by alternating gradient ascent in numpy. Select 50 anchor items with k-means on item parameters. Estimate a new model's full-benchmark accuracy and compare the error with random 50-item subsets.
10. **`snr.py`:** mock "training checkpoints" whose scores follow a trend plus noise. Compute the AI2 signal, noise, SNR and decision accuracy. Show that switching from 0/1 accuracy to a continuous log-prob metric raises SNR.
11. **`ppi.py`:** a mock LLM judge with a known bias and 5,000 judged items, plus 200 human-labelled items. Compare the naive judge mean (biased), the human-only CI (wide) and the PPI estimate with its CI.
12. **`seeds_nondeterminism.py`:** run a mock eval with a seeded RNG versus "batch-dependent" noise, illustrating TARa@N and why you report mean ± sd over seeds.

---

## 5. Pitfalls, debates, open problems and practitioner recommendations

### Common pitfalls

- **Bare point estimates** on leaderboards and in papers, with no n, no SE and no seeds.
- **Comparing overlapping CIs instead of testing the paired difference.** Overlapping 95% CIs do not imply "no significant difference", and the unpaired approach discards the correlation between models.
- **Treating K samples per question as K·n independent observations.** This understates the SE. Cluster by question or average within each question first.
- **Ignoring clusters** (passages, repos, environments, conversation trajectories, multi-turn tasks from the same user scenario).
- **Using the CLT on 30-item benchmarks** (AIME, small agentic suites). Use Wilson or Bayes intervals, or more seeds and more items.
- **Selecting on the test set.** Picking the best of several prompts, seeds or checkpoints and reporting it inflates results (Hochlehnert et al.; Dehghani et al.; Henderson et al.). Agarwal et al. note that a "max over evaluations" protocol inflated scores.
- **Lowering temperature to "remove noise".** This changes the quantity being measured (Miller). Report sampling parameters instead.
- **Assuming temperature 0 is deterministic.** It is not, because of batch variance, hardware and kernels (Atil et al.; Thinking Machines).
- **Unseeded bootstraps,** and too few bootstrap replicates for tail percentiles.
- **Hardware and framework drift** between baseline and treatment runs (up to 8 points in Hochlehnert et al.).
- **Multiple comparisons** across many benchmarks, subtasks or model pairs with no correction.
- **Aggregating across tasks with the mean** when a few tasks have huge scores (Atari-style normalized scores). Prefer IQM, or report per-task results.
- **Underpowered evals.** Running an eval that could never detect the effect of interest (Card et al.).
- **pass@k with k close to n,** or with a different n across models. Report n. pass@k also rewards diversity and can mask unreliability, so report pass^k for agents.

### Debates and open problems

- **Frequentist vs Bayesian.** Bowyer et al. and Hariri et al. push Bayesian credible intervals for small n. Miller's framework is frequentist CLT and is adequate for n in the hundreds or more. Recommendation: CLT for large n, Wilson or Bayes for small n, and say which you used.
- **Significance testing vs estimation.** Agarwal et al. argue against dichotomous p < 0.05 decisions. Others (Dror et al.; Colas et al.) recommend tests with proper choices. A growing consensus is to report effect sizes with intervals.
- **Does IRT reduce variance?** tinyBenchmarks, metabench and Fluid say it helps efficiency and even variance (Fluid). Madaan et al. find that IRT subsets increase seed variance in pretraining comparisons. This is open, and the answer depends on whether you are ranking final models or tracking training.
- **Which noise dominates?** Wang (2025) says prediction noise usually exceeds data noise in paired comparisons. That implies large gains from K-sample averaging. The extent varies across evals.
- **What population are we inferring to?** The super-population framing assumes the questions are an i.i.d. sample from a meaningful distribution. Real benchmarks are curated and non-random, so CIs capture sampling noise but not construct validity or contamination.
- **Agent evals.** Episodes are long, costly, multi-step and correlated (same environment, same user simulator). Hierarchical models (HiBayES), clustered SEs by environment, and pass^k are emerging practice. There is no single standard yet.
- **LLM-as-judge noise.** Judge variance adds a measurement-error layer. PPI handles judge bias with a small amount of human data, but needs gold labels.
- **Benchmark saturation and dynamic benchmarks** change the denominator over time, which complicates longitudinal comparisons.

### What practitioners recommend: a consolidated checklist

1. Report n (questions), the number of clusters, K (samples per question), the number of seeds or runs, and the decoding parameters.
2. Report mean ± SE (or a 95% CI) for every number. Use clustered SEs when items are grouped, and Wilson or Bayesian intervals when n < a few hundred.
3. Compare models with paired, question-level differences. Report the difference, its SE and the correlation between models.
4. Do a power or MDE calculation before running. State the smallest effect your eval can detect.
5. Prefer continuous metrics or token probabilities where valid, and average over K samples to cut prediction noise.
6. For agents, report pass^k (reliability) alongside pass@1 and pass@k, with n per task.
7. For RL, use at least 10 runs where possible. Report IQM with stratified bootstrap CIs and performance profiles, and release per-run scores.
8. Correct for multiple comparisons (Holm or BH), or pre-register the primary metric.
9. Fix and report the software and hardware stack (container, inference engine version, GPU type). Seed everything, including the bootstrap.
10. Release prompts, raw per-item outputs and scores, so others can recompute the statistics.

---

## 6. Suggested sub-sections for the book chapter "Statistics and Rigor in Evals"

1. **Why an eval score is an estimate.** The super-population view and the four sources of variance, with the law of total variance as the organizing figure.
2. **Error bars for a single model.** CLT SE, Bernoulli SE and 95% CIs. When the CLT fails: Wilson, Clopper–Pearson and Beta posteriors (runnable coverage simulation).
3. **Clustered data.** Passages, repos, environments and repeated samples. Clustered SE and the cluster bootstrap (Inspect code walkthrough).
4. **Reducing variance.** K resamples, token probabilities, continuous metrics (BPB) and checkpoint averaging. Why not to lower temperature.
5. **Comparing two models.** Paired differences, McNemar, the paired permutation test and the paired bootstrap, with a worked example showing how pairing shrinks the SE.
6. **Power analysis and sample size.** Miller's formula, an MDE table and a simulation check. "Can your eval even see the effect?"
7. **Multiple comparisons and leaderboards.** FWER vs FDR (Bonferroni, Holm, BH), simultaneous CIs for rankings (Chatbot Arena) and the benchmark lottery.
8. **The bootstrap toolbox.** Percentile, basic and BCa intervals; stratified, cluster and paired variants; seeding; pitfalls at small n.
9. **Stochastic agents: pass@k, pass^k and Bayes@N.** Unbiased estimators, the Agent A vs Agent B example and reliability reporting.
10. **Nondeterminism and reproducibility.** Seeds, temperature, hardware, batch invariance, TARa@N, and the "Sober Look" case study.
11. **Benchmark quality: signal, noise and decision accuracy.** AI2 SNR, Madaan monotonicity, choosing benchmarks for training ablations.
12. **Psychometrics: IRT and efficient evaluation.** 2PL, tinyBenchmarks, metabench, anchor points, Fluid adaptive testing and PromptEval, plus the counter-evidence.
13. **Statistics for RL and RL environments.** The statistical precipice, IQM, performance profiles, probability of improvement, optimality gap and rliable, with how to map these to LLM-agent RL environments (tasks = environments, runs = rollout seeds).
14. **Mixing judge and human labels.** Prediction-powered inference and AutoEval.
15. **Hierarchical Bayesian evaluation** for small, nested agentic evals (HiBayES, bayes_evals).
16. **A reporting checklist and template table.** A copy-pasteable results table with n, K, seeds, mean, SE, CI, paired difference and p or posterior probability.

Each section should come with one runnable script from Section 4.6 (stdlib plus numpy, mocked models, fixed seeds).
