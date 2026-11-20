# Research Dossier 02: Benchmarks and Metrics for LLMs

*Compiled 2026-11-20 for the book "Evaluations for AI: LLMs, Agents and RL Environments".*

**How sources were verified.** I opened every arXiv paper's abstract page (arxiv.org/abs/<id>) and checked the title, first authors, submission date and the claims attributed to the abstract. For the Codex paper I also read the full PDF text, to check the HumanEval size, n=200 and the unbiased estimator. For GitHub repos I got star counts and last-push dates from the GitHub search API on 2026-11-20, and I read the code snippets from the raw files on the default branch. I fetched the blog and documentation pages directly.

- **verified: yes** means the title, authors, year and URL were all checked, and the claim is in the source I opened.
- **verified: partial** means the source exists but some detail could not be checked directly. Typical cases are numbers that appear only in the paper body, or claims that come from search snippets.

---

## 1. Overview: how the area fits together

The evaluation stack for a language model has five layers. Most of the chapter can be organised around them.

1. **Task / dataset (the benchmark).** A fixed set of items, each with an input and either a reference answer or a checker. Benchmarks can be grouped by what they test:
   - Knowledge and reasoning, multiple choice (MC): MMLU, MMLU-Pro, GPQA, ARC, HellaSwag.
   - Math, generative with a verifiable final answer: GSM8K, MATH, AIME / MathArena, FrontierMath.
   - Code, checked by executing tests: HumanEval, MBPP, LiveCodeBench.
   - Factuality: TruthfulQA, SimpleQA.
   - "Frontier" closed-ended exams: Humanity's Last Exam (HLE).
   - Fluid-intelligence puzzles: ARC-AGI.
   - Instruction following: IFEval.
   - Open-ended chat, judged by humans or LLMs: Chatbot Arena / LMArena, MT-Bench, AlpacaEval, Arena-Hard.
   - Suites of many tasks: BIG-bench, BBH, HELM, the Open LLM Leaderboard.
2. **Elicitation protocol.** The prompt template, the number of few-shot examples (k-shot) and how they are formatted, whether chain-of-thought (CoT) is used, the decoding settings (greedy vs temperature, number of samples n), and whether the model generates freely or is scored by log-probability. These choices often move scores by more than the gap between models (Sclar et al. 2023; Alzahrani et al. 2024).
3. **Scoring function (per item).**
   - Exact match after normalisation, regex answer extraction, and symbolic equivalence (MATH).
   - Token F1 (SQuAD).
   - n-gram overlap (BLEU, ROUGE) or embedding similarity (BERTScore).
   - Executing unit tests (pass/fail).
   - argmax over choice log-likelihoods (acc, acc_norm).
   - A judge verdict: an LLM or a human gives a pairwise preference or a graded label.
4. **Aggregation (per benchmark).**
   - Mean accuracy, and macro- vs micro-averaging over subjects.
   - pass@k with the unbiased estimator.
   - Perplexity and bits-per-byte.
   - Calibration (ECE, Brier score).
   - SimpleQA's correct / incorrect / not-attempted with an F1-like summary.
   - Pairwise preferences turned into ratings (Elo, Bradley–Terry, with style control).
   - Normalising against a random-guess baseline (Open LLM Leaderboard).
5. **Uncertainty and meta-evaluation.**
   - Standard errors, clustered SEs, paired differences and power analysis (Miller 2024).
   - Seed variance and signal-to-noise (Madaan et al. 2024; Heineman et al. 2025).
   - Label noise (MMLU-Redux, "platinum benchmarks").
   - Contamination (GSM1k, rephrased samples, LiveBench / LiveCodeBench / MathArena).
   - Saturation (Akhtar et al. 2026; Epoch "Rosetta Stone").
   - Leaderboard gaming (The Leaderboard Illusion).

**How the parts relate.** A "score" is a function of all five layers: *score = Aggregate(Score(Model(Prompt(item))))* over the item set, and it comes with sampling noise. Benchmark cards and leaderboards usually report only the dataset name, so most cross-paper comparisons are underspecified.

A short history of the field:
- **Accuracy era, 2018–2021:** ARC, HellaSwag, MMLU, GSM8K, MATH, HumanEval.
- **Holistic multi-metric era, 2022:** HELM, BIG-bench.
- **Preference / judge era, 2023–2024:** Chatbot Arena, MT-Bench, AlpacaEval LC, Arena-Hard.
- **Contamination-resistant and frontier-difficulty era, 2024–2026:** GPQA, MMLU-Pro, LiveCodeBench, LiveBench, FrontierMath, HLE, ARC-AGI-2, MathArena.
- **Running through all of them:** benchmarks saturate faster and faster, and more attention goes to statistics, label quality, and the validity of leaderboards.

---

## 2. Key concepts, definitions, formulas and worked examples

All numbers in the worked examples below were computed with Python while writing this dossier.

### 2.1 Accuracy, exact match (EM) and normalisation

- **Accuracy** = (1/N) Σᵢ 1[predᵢ = goldᵢ].
- **Exact match** compares strings after a normalisation function. The SQuAD v1.1 official script (reproduced in HF `evaluate`, `metrics/squad/compute_score.py`) does four things, in this order of application:
  1. lowercases the text;
  2. removes punctuation;
  3. removes the articles `a|an|the`;
  4. collapses whitespace.
- When an item has several references, the score is the maximum over the gold answers (`metric_max_over_ground_truths`).
- **Answer extraction** is part of the metric:
  - GSM8K's reference code extracts the final answer with the regex `#### (\-?[0-9\.\,]+)` and strips commas.
  - simple-evals extracts multiple-choice answers with `(?i)Answer[ \t]*:[ \t]*\$?([A-D])\$?`.
  - MATH compares answers with `is_equiv` after `_strip_string`, which fixes `\frac`, `\sqrt`, units, `a/b`, and so on.
  - A different extractor changes the score even when the model output is identical.

### 2.2 Token-level F1 (SQuAD-style)

P = |pred ∩ gold| / |pred|, R = |pred ∩ gold| / |gold|, F1 = 2PR/(P+R). The intersection is a bag-of-tokens intersection (multiset), computed after normalisation.

*Worked example:*
- pred = "The cat sat on the mat." normalises to [cat, sat, on, mat].
- gold = "A cat was sitting on the mat" normalises to [cat, was, sitting, on, mat].
- Overlap = 3, so P = 3/4 = 0.75, R = 3/5 = 0.60, and **F1 = 0.667**. EM = 0.

### 2.3 BLEU (Papineni et al., 2002)

BLEU = BP · exp( Σₙ wₙ log pₙ ), with:
- pₙ = the *clipped* (modified) n-gram precision, n = 1..4;
- wₙ = 1/4;
- BP = 1 if c > r, else exp(1 − r/c), where c is the candidate length and r the reference length.

*Worked example 1:*
- candidate "the cat is sitting on the mat", reference "the cat sat on the mat".
- p₁ = 5/7, p₂ = 3/6, p₃ = 1/5, p₄ = 0/4.
- Because p₄ = 0, **sentence BLEU = 0** without smoothing. This is the classic reason sentence-level BLEU needs smoothing (sacrebleu provides methods for it) and why BLEU is meant to be computed at corpus level.

*Worked example 2:*
- candidate "the cat sat on the red mat today", reference "the cat sat on the mat today".
- p = 7/8, 5/7, 3/6, 2/5, and BP = 1.
- **BLEU ≈ 0.595**.

BLEU has parameters (tokenisation, casing, smoothing, number of references). Post (2018) shows that differences between commonly used configurations reach 1.8 BLEU, and introduced sacreBLEU with a version "signature" so that scores can be compared.

### 2.4 ROUGE (Lin, 2004)

- **ROUGE-N** is n-gram *recall* against the reference(s).
- **ROUGE-L** uses the longest common subsequence (LCS): R_lcs = LCS/|ref|, P_lcs = LCS/|cand|, and F is their harmonic mean (β-weighted in the original paper).

*Worked example:* for the example 1 pair above, LCS = 5 ("the cat on the mat"), P = 5/7 = 0.714, R = 5/6 = 0.833, **ROUGE-L F1 = 0.769**. Note that BLEU was 0 for the same pair, so the two metrics disagree sharply.

### 2.5 BERTScore (Zhang et al., 2019)

Each token is embedded with a contextual encoder. Each candidate token is greedily matched to the reference token with the highest cosine similarity:
- R_BERT = (1/|x|) Σ_{xᵢ∈x} max_{x̂ⱼ∈x̂} xᵢᵀx̂ⱼ (x = reference, x̂ = candidate);
- P_BERT is defined symmetrically over the candidate tokens;
- F_BERT = 2PR/(P+R).

Optional extras are idf weighting and "baseline rescaling". Scores are only comparable when the same model and layer are used. The `bert_score` package prints a hash string for this purpose.

*Teaching example:* toy word vectors in numpy, so that "sat" and "sitting" have cosine 0.9. This shows BERTScore rewarding paraphrases that BLEU and ROUGE miss.

### 2.6 Perplexity, log-likelihood and bits-per-byte

- PPL = exp( −(1/T) Σₜ log p(xₜ | x<ₜ) ).
- In lm-eval-harness the aggregation is literally `math.exp(-mean(items))`.
- `weighted_perplexity` normalises by word count, and `bits_per_byte` = −Σ log p / (bytes · ln 2). The byte- and word-normalised forms can be compared across tokenizers; token-level PPL cannot.

*Worked example:* token probabilities [0.5, 0.25, 0.125, 0.5] give mean log p = −1.2130 and **PPL = 3.364**.

### 2.7 Log-probability (likelihood) scoring vs generative scoring

**Log-prob MC scoring.** For each choice cⱼ, compute the log-likelihood of cⱼ as the continuation of the prompt, ℓⱼ = Σ log p(tokens of cⱼ | prompt). There are several ways to turn these into a prediction, all in lm-eval-harness `lm_eval/api/task.py`:
- `acc`: pred = argmax ℓⱼ.
- `acc_norm`: argmax ℓⱼ / len_chars(cⱼ).
- `acc_bytes`: normalise by UTF-8 byte length.
- `acc_mutual_info`: argmax (ℓⱼ − ℓⱼ^uncond), i.e. subtract the log-likelihood of the choice given an empty context.
- `exact_match` in the MC setting = whether the gold continuation is the greedy decode.
- `brier_score` is computed over the softmax of the ℓⱼ.

There is also a choice of what to score:
- *Cloze* formulation: score the answer text itself.
- *MCF / letter* formulation: present the options labelled A–D and score the single letter token.

**Generative scoring.** The model produces free text (often with CoT), an answer is extracted (regex / parser), and the extracted answer is compared (EM, symbolic equivalence, or an LLM grader). simple-evals deliberately emphasises "the *zero-shot, chain-of-thought* setting" because it better reflects realistic usage (README).

**Trade-offs:**
- Log-prob scoring is cheap, deterministic and works for base models, but it needs logits (unavailable from many APIs).
- Log-prob scoring is biased toward short or frequent strings, hence the normalisations.
- With log-prob scoring, CoT cannot help.
- Generative scoring matches real use, but adds extraction errors and sampling noise.
- Alzahrani et al. (2024) find that changing the answer-selection method moves rankings by up to 8 places and recommend a hybrid method.
- Madaan et al. (2024) find that framing MC tasks like MMLU as completion (cloze) tasks reduces variance for models around 7B.
- MMLU-Pro reports that CoT *helps* on MMLU-Pro but not on the original MMLU.

### 2.8 pass@k and the unbiased estimator (Chen et al., 2021, Codex paper)

pass@k is the probability that at least one of k samples passes the unit tests.

The naive way to estimate it (draw exactly k samples, count a success if any passes) has high variance. Instead:
1. Draw n ≥ k samples per problem (the paper uses n = 200, k ≤ 100).
2. Count the passing ones, c.
3. Compute

   pass@k = E_problems[ 1 − C(n−c, k) / C(n, k) ].

This is unbiased because it estimates the probability that all k draws come from the n−c failures, sampling *without replacement*.

Computing the binomial coefficients directly overflows, so the reference implementation (`openai/human-eval`, `human_eval/evaluation.py`) uses a product form:

```python
def estimator(n: int, c: int, k: int) -> float:
    """
    Calculates 1 - comb(n - c, k) / comb(n, k).
    """
    if n - c < k:
        return 1.0
    return 1.0 - np.prod(1.0 - k / np.arange(n - c + 1, n + 1))
```

*Worked examples:*
- n = 10, c = 3: pass@1 = 0.300 and pass@5 = 1 − C(7,5)/C(10,5) = 1 − 21/252 = **0.9167**.
- n = 200, c = 10: pass@1 = 0.050, pass@10 = 0.4085, pass@100 = 0.9992.

*Bias demonstration (exact expectation over Binomial(n=10, p=0.1), k=5):*
- The true pass@5 is 1 − 0.9⁵ = 0.4095.
- The unbiased estimator's expectation is 0.4095.
- The "plug-in" estimator 1 − (1 − c/n)^k has expectation **0.3485**, biased low by about 6 points. This makes a good exercise.

Related points:
- pass@1 with n samples equals the mean of c/n. Report it alongside its SE.
- MBPP (Austin et al. 2021) has 974 tasks. HumanEval has 164 hand-written problems with about 7.7 tests per problem (Codex paper, verified in the PDF).
- "Large Language Monkeys" (Brown et al. 2024) call pass@k at large k "coverage" and find that it often grows log-linearly with the number of samples over four orders of magnitude.
- pass@k ≠ what you get in deployment unless you have a verifier. Selection methods without a verifier (majority vote, reward models) plateau.

### 2.9 Calibration: ECE and Brier score

- **ECE** (Guo et al. 2017 popularised it for neural nets). Partition predictions into M confidence bins Bₘ. Then

  ECE = Σₘ (|Bₘ|/N) · |acc(Bₘ) − conf(Bₘ)|.

- **MCE** is the maximum gap over bins.
- **Brier score** = (1/N) Σ (pᵢ − yᵢ)². For K classes it is summed over the classes. lm-eval-harness computes it over the softmax of the choice log-likelihoods.

*Worked example:* 10 predictions, 5 equal-width bins.

| bin | n | mean conf | accuracy | contribution |
|---|---|---|---|---|
| (0, .2] | 1 | 0.20 | 0.00 | 0.020 |
| (.2, .4] | 2 | 0.275 | 0.50 | 0.045 |
| (.4, .6] | 2 | 0.575 | 0.00 | 0.115 |
| (.6, .8] | 2 | 0.725 | 1.00 | 0.055 |
| (.8, 1] | 3 | 0.90 | 0.667 | 0.070 |

**ECE = 0.305.**

Caveats:
- ECE depends on the number of bins and on the binning scheme (equal-width vs equal-mass).
- ECE is biased upward when N is small.
- For LLMs, "confidence" can be the token probability of the answer letter, a verbalised confidence, or agreement among samples.
- HLE reports that frontier models have *low calibration* as well as low accuracy. HELM treats calibration as one of its 7 core metrics.

### 2.10 Pairwise preference: Elo and Bradley–Terry (Chatbot Arena / LMArena)

**Online Elo.** The expected score is E_A = 1/(1 + 10^{(R_B − R_A)/400}), and after each battle R_A ← R_A + K(S_A − E_A). FastChat's `compute_elo` uses K = 4, base 10, scale 400 and init 1000.
- *Worked example:* R_A = 1200 and R_B = 1000 give E_A = 0.760. If A wins with K = 4, R_A rises by 0.961.
- Online Elo depends on the order of battles and is noisy.

**Bradley–Terry (BT).** P(A beats B) = σ(β_A − β_B), fitted by maximum likelihood (logistic regression) over all battles; the result does not depend on order. LMArena moved from online Elo to BT. FastChat `rating_systems.py`:
- `fit_bt` minimises a weighted cross-entropy with L-BFGS-B. The comment in the code says "this form naturally counts a draw as half a win and half a loss".
- Ratings are rescaled as `ratings * scale + init_rating`, then anchored so that `mixtral-8x7b-instruct-v0.1 = 1114`.
- Confidence intervals come from a bootstrap over battles (`compute_bootstrap_bt`).

**Style control** (LMSYS blog, 2024-08-29):
- Adds style covariates Z to the regression: σ(Xᵀβ + Zᵀγ).
- The covariates are the normalised differences (a − b)/(a + b) in answer token length, number of markdown headers, number of bold elements, and number of list elements.
- Fitted coefficients: length 0.249, list 0.031, header 0.024, bold 0.019. Length dominates.
- Rankings shift. For example, grok-2-mini fell from rank 6 to rank 18 overall when both length and markdown were controlled, and claude-3-opus rose from 16 to 10.

**Length-controlled AlpacaEval** (Dubois et al. 2024) uses the same idea for LLM-judge win rates. It fits a GLM with a length-difference term and predicts the win rate at zero length difference, which raises the Spearman correlation with Chatbot Arena from 0.94 to 0.98.

### 2.11 Score normalisation against the chance baseline (Open LLM Leaderboard v2)

norm = (raw − lower) / (1 − lower) × 100. Scores below the chance baseline are clipped to 0.

Examples from the HF docs:
- GPQA (4 choices, lower bound 0.25): raw 0.60 gives **46.67**.
- MuSR has three subtasks, normalised separately and then averaged:
  - murder mysteries (2 choices): raw 0.7 gives 40.00;
  - object placement (5 choices): raw 0.4 gives 25.00;
  - team allocation (3 choices): raw 0.6 gives 40.00;
  - average **35.00**.
- Generative tasks (MATH, IFEval) use a lower bound of 0.

Normalising this way removes the "free" 25% on 4-way MC questions, so a 10-choice benchmark (MMLU-Pro) and a 4-choice one can be put on one scale.

### 2.12 Statistical uncertainty (Miller 2024, "Adding Error Bars to Evals")

- **Standard error and CI.** Treat items as draws from a super-population. SE = sqrt(p̂(1 − p̂)/N) for binary scores (or sample std/√N in general; lm-eval's `mean_stderr`). The 95% CI is p̂ ± 1.96·SE.
  - *Worked example:* 80% accuracy on N = 1000 gives SE = 1.26 pp and CI [77.5, 82.5].
  - *Worked example:* on a 198-item set (GPQA-Diamond size; partially verified, since 198 comes from common usage rather than the GPQA abstract, which reports 448 items for the main set) at 50% accuracy, SE = 3.55 pp, so the CI is about ±7 pp.
- **Clustered SEs.** Use them when items share a passage or template. The Anthropic blog states that clustered SEs were "over three times" the naive SEs on popular evals.
- **Paired differences.** Var(d̄) = (σ_A² + σ_B² − 2ρσ_Aσ_B)/N. Frontier models show ρ ≈ 0.3–0.7 on popular evals, so pairing shrinks the SE.
- **Reduce within-item variance.** Resample several CoT answers per item and average them, or use next-token probabilities in place of sampled answers.
- **Power analysis.** Choose N (and the number of resamples) needed to detect a given effect size, for example 3 pp.
- **Bootstrap SEs.** simple-evals' `_compute_stat` offers `bootstrap_std` (1000 resamples), and FastChat bootstraps the battles.

### 2.13 Signal, noise and benchmark variance

- **Heineman et al. (2025).** *Signal* is how well a benchmark separates better models from worse ones; *noise* is its sensitivity to variation between training steps. A higher signal-to-noise ratio (SNR) predicts more reliable decisions at small scale and lower scaling-law error. They recommend continuous metrics (perplexity / bits-per-byte rather than accuracy), filtering noisy subtasks, and averaging checkpoints.
- **Madaan et al. (2024).** Measure seed variance and monotonicity during training. Item analysis and IRT struggled to reduce variance meaningfully.
- **Schaeffer et al. (2023), "Mirage".** Discontinuous metrics (exact match, accuracy) make abilities look "emergent", while continuous metrics on the same outputs show smooth improvement. This links directly to the choice of metric.

### 2.14 Prompt sensitivity and few-shot formatting

- Sclar et al. (2023), FormatSpread: up to **76 accuracy points** spread across meaning-preserving formatting changes (LLaMA-2-13B, few-shot). Sensitivity persists as model size, number of shots and instruction tuning increase. The ranking of formats correlates only weakly between models. Recommendation: report a *range* over plausible formats.
- MMLU-Pro: across 24 prompt styles, sensitivity falls from 4–5% (MMLU) to 2% (MMLU-Pro).
- Alzahrani et al. (2024): changing the order of choices, the answer-symbol style, or the scoring method moves leaderboard rank by up to 8 positions.

### 2.15 Contamination, saturation and label noise

- **Contamination.** GSM1k (Zhang et al. 2024) is a fresh, matched copy of GSM8K. Accuracy drops by up to 8% on it, and the gap correlates with the probability of generating GSM8K examples (r² = 0.36), but frontier models showed minimal overfitting. Yang et al. (2023) show that paraphrased or translated test items bypass n-gram decontamination; a 13B model fine-tuned on rephrased samples reaches GPT-4-level scores. Dynamic, time-stamped benchmarks are the mitigation: LiveCodeBench (problems carry release dates, so you can evaluate after the model's cutoff), LiveBench, MathArena (fresh competitions), and FrontierMath / HLE (unpublished, held-out items).
- **Saturation.** Akhtar et al. (2026) analysed 60 benchmarks: nearly half are saturated, the rate grows with age, and expert curation (rather than keeping test data private) is associated with longevity. Epoch's Rosetta Stone (Ho et al. 2025) shows that most benchmarks saturate "within years or even months" and stitches benchmarks onto a single IRT-like scale. HLE motivates itself with MMLU accuracies above 90%.
- **Label noise.** MMLU-Redux estimates that 6.49% of MMLU questions contain errors, and 57% of the analysed Virology questions. Vendrow et al. (2025) find that label errors are pervasive and propose "platinum" benchmarks. Noise sets a ceiling on what is measurable and hides real failures. GPQA reports that experts score 65%, or 74% after discounting mistakes they spotted in retrospect.
- **Leaderboard validity.** The Leaderboard Illusion (Singh et al. 2025) finds that undisclosed private testing let providers publish only their best variant (27 Llama-4 private variants were tested), and that data access is asymmetric (Google 19.2% and OpenAI 20.4% of arena data, versus 29.7% for 83 open-weight models combined).

---

## 3. Annotated source list (validated)

Star counts and last-push dates come from the GitHub search API on 2026-11-20.

### Benchmarks: knowledge, reasoning and commonsense

1. **Hendrycks et al., "Measuring Massive Multitask Language Understanding" (MMLU)**, arXiv:2009.03300, 2020. https://arxiv.org/abs/2009.03300. 57 subjects. The largest GPT-3 was about 20 pp above chance, and models "do not know when they are wrong" (an early calibration finding). Repo hendrycks/test: 1,625★, last push 2023-05. **verified: yes**
2. **Wang et al., "MMLU-Pro"**, arXiv:2406.01574, 2024. Expands from 4 to 10 options and removes trivial or noisy items. Accuracy is 16–33% lower than on MMLU, prompt sensitivity falls from 4–5% to 2% across 24 prompts, and CoT helps. Repo TIGER-AI-Lab/MMLU-Pro: 435★, last push 2026-03. **verified: yes**
3. **Gema et al., "Are We Done with MMLU?" (MMLU-Redux)**, arXiv:2406.04127, 2024. Error-annotation protocol. Estimates 6.49% of MMLU questions are wrong (57% in Virology) and releases 5,700 re-annotated items. Shows that rankings shift when evaluated on the corrected labels. **verified: yes**
4. **Rein et al., "GPQA: A Graduate-Level Google-Proof Q&A Benchmark"**, arXiv:2311.12022, 2023. 448 expert-written questions in biology, physics and chemistry. Experts score 65% (74% excluding mistakes they recognised), skilled non-experts with web access 34%, and the GPT-4 baseline 39%. Designed for scalable-oversight research. Repo idavidrein/gpqa: 551★. **verified: yes** (the Diamond subset size of 198 is **partial**: it is not in the abstract).
5. **Zellers et al., "HellaSwag"**, arXiv:1905.07830, 2019. Adversarial Filtering produced commonsense completions that are trivial for humans (>95%) but hard for 2019 models (<48%). The canonical example of a benchmark built adversarially against current models and saturated soon after. **verified: yes**
6. **Clark et al., "Think you have Solved Question Answering? Try ARC"**, arXiv:1803.05457, 2018. 7,787 grade-school science questions. The Challenge set is filtered to questions that a retrieval algorithm and a co-occurrence algorithm both get wrong. A standard log-prob MC task in harnesses (`acc_norm`). **verified: yes**
7. **Srivastava et al., "Beyond the Imitation Game" (BIG-bench)**, arXiv:2206.04615, 2022. 204 tasks from 450 authors at 132 institutions; studies how capabilities extrapolate with scale. Repo google/BIG-bench: 3,243★, last push 2024-07 (effectively frozen). **verified: yes**
8. **Suzgun et al., "Challenging BIG-Bench Tasks and Whether Chain-of-Thought Can Solve Them" (BBH)**, arXiv:2210.09261, 2022. A hard subset of BIG-bench used in Open LLM Leaderboard v2; shows CoT gains. **verified: yes** (title, authors and date checked; the CoT claim comes from the title).
9. **Chollet, "On the Measure of Intelligence"**, arXiv:1911.01547, 2019, and **Chollet et al., "ARC-AGI-2"**, arXiv:2505.11831, 2025. The first defines intelligence as skill-acquisition efficiency and introduces ARC. The second keeps the input/output grid format but adds harder tasks and extensive human testing. Repos fchollet/ARC-AGI 4,855★ and arcprize/ARC-AGI-2 749★. **verified: yes**
10. **Phan et al., "Humanity's Last Exam"**, arXiv:2501.14249, 2025. 2,500 expert questions (multiple choice and short answer), multimodal, designed to be the "final closed-ended academic benchmark". Frontier models show low accuracy *and* poor calibration. Repo centerforaisafety/hle: 1,748★, last push 2026-09. **verified: yes**

### Benchmarks: math and code

11. **Cobbe et al., "Training Verifiers to Solve Math Word Problems" (GSM8K)**, arXiv:2110.14168, 2021. 8.5K grade-school problems. Introduces verifier reranking (best-of-n with a learned verifier). The final-answer format `#### <num>` enables exact-match grading. Repo openai/grade-school-math: 1,460★. **verified: yes**
12. **Hendrycks et al., "Measuring Mathematical Problem Solving With the MATH Dataset"**, arXiv:2103.03874, 2021. 12,500 competition problems with step-by-step solutions. The `is_equiv` / `_strip_string` normaliser for LaTeX answers became a de facto standard. Repo hendrycks/math: 1,397★. **verified: yes**
13. **Zhang et al., "A Careful Examination of LLM Performance on Grade School Arithmetic" (GSM1k)**, arXiv:2405.00332, 2024. A matched, fresh copy of GSM8K. Drops of up to 8%, with signs of systematic overfitting in some model families; r² = 0.36 between the likelihood of generating GSM8K and the performance gap. **verified: yes**
14. **Mirzadeh et al., "GSM-Symbolic"**, arXiv:2410.05229, 2024. Generates GSM8K variants from templates. Performance falls when only the numbers change, and degrades as clauses are added. Illustrates variance across instantiations. **verified: yes**
15. **Glazer et al., "FrontierMath"**, arXiv:2411.04872, 2024 (Epoch AI). Hundreds of unpublished, expert-crafted problems with automated verification; state-of-the-art models solved under 2% at release. **verified: yes**
16. **Balunović et al., "MathArena: Evaluating LLMs on Uncontaminated Math Competitions"**, arXiv:2505.23281, 2025. Uses fresh competitions (AIME etc.) after model release to avoid contamination, and also evaluates proofs. The best reference for "AIME as a benchmark". **verified: yes**
17. **Chen et al., "Evaluating Large Language Models Trained on Code" (Codex / HumanEval)**, arXiv:2107.03374, 2021. 164 hand-written problems (about 7.7 tests each). The unbiased pass@k estimator (n = 200, k ≤ 100) with a numerically stable implementation. Codex-12B scores 28.8% pass@1 and 70.2% with 100 samples. Repo openai/human-eval: 3,431★, last push 2026-10. **verified: yes** (full PDF text checked).
18. **Austin et al., "Program Synthesis with Large Language Models" (MBPP)**, arXiv:2108.07732, 2021. 974 entry-level Python tasks, plus MathQA-Python. Few-shot vs fine-tuning, for models from 244M to 137B parameters. **verified: yes**
19. **Jain et al., "LiveCodeBench"**, arXiv:2403.07974, 2024. Continuously collects problems from LeetCode, AtCoder and CodeForces with timestamps. Tests self-repair, code execution and test-output prediction. Contamination is visible as a drop for problems released after the model's cutoff. Repo LiveCodeBench/LiveCodeBench: 979★, last push 2025-07. **verified: yes**
20. **Brown et al., "Large Language Monkeys"**, arXiv:2407.21787, 2024. Coverage (pass@k) scales roughly log-linearly with samples over 4 orders of magnitude, modelled with an exponentiated power law. Relevant to interpreting pass@k at large k. **verified: yes**

### Factuality, instruction following and preference

21. **Lin et al., "TruthfulQA"**, arXiv:2109.07958, 2021. 817 questions in 38 categories aimed at imitative falsehoods. The best model was truthful on 58% of questions vs 94% for humans; larger models were often less truthful (inverse scaling). **verified: yes**
22. **Wei et al., "Measuring short-form factuality in large language models" (SimpleQA)**, arXiv:2411.04368, 2024 (OpenAI). Adversarially collected against GPT-4. Each answer is graded correct, incorrect or not attempted, which rewards abstaining. The code computes `accuracy_given_attempted` and an F1 = harmonic mean of overall correct and accuracy-given-attempted. **verified: yes** (abstract and simple-evals code).
23. **Zhou et al., "Instruction-Following Evaluation for LLMs" (IFEval)**, arXiv:2311.07911, 2023. Verifiable instructions ("write more than 400 words") checked programmatically, with strict and loose accuracy at prompt and instruction level. **verified: yes** (title and authors; metric details from the HF leaderboard docs).
24. **Zheng et al., "Judging LLM-as-a-Judge with MT-Bench and Chatbot Arena"**, arXiv:2306.05685, 2023. MT-Bench; LLM judges show position, verbosity and self-enhancement biases; strong judges agree with humans about as well as humans agree with each other (the agreement figure is **partial**, from the paper body). **verified: yes**
25. **Chiang et al., "Chatbot Arena: An Open Platform for Evaluating LLMs by Human Preference"**, arXiv:2403.04132, 2024. Crowdsourced pairwise votes (240K+ at the time), statistical ranking with BT, and an analysis of prompt diversity and agreement with experts. Repo lm-sys/FastChat: 39,549★, last push 2026-05 (contains `rating_systems.py`). **verified: yes**
26. **Li, Angelopoulos, Chiang, "Does style matter? Disentangling style and substance in Chatbot Arena"**, LMSYS blog, 2024-08-29, https://lmsys.org/blog/2024-08-28-style-control. BT regression with style covariates; coefficients and rank shifts as given in §2.10. **verified: yes**
27. **Li et al., "From Crowdsourced Data to High-Quality Benchmarks: Arena-Hard and BenchBuilder"**, arXiv:2406.11939, 2024. Uses LLMs to build hard prompt sets automatically from Arena and WildChat data. **verified: yes** (title, authors and abstract start).
28. **Dubois et al., "Length-Controlled AlpacaEval"**, arXiv:2404.04475, 2024. GLM debiasing of the length confounder in LLM-judge win rates; Spearman correlation with Arena rises from 0.94 to 0.98. Repo tatsu-lab/alpaca_eval: 2,026★. **verified: yes**
29. **Singh et al., "The Leaderboard Illusion"**, arXiv:2504.20879, 2025 (Cohere and collaborators). Private testing and selective disclosure, 27 Meta variants before Llama-4, and asymmetric data access. Essential reading on gaming the Arena. **verified: yes**

### Holistic suites, harnesses and reporting practice

30. **Liang et al., "Holistic Evaluation of Language Models" (HELM)**, arXiv:2211.09110, 2022. A taxonomy of scenarios × metrics; 7 metrics (accuracy, calibration, robustness, fairness, bias, toxicity, efficiency); standardised conditions. Repo stanford-crfm/helm: 2,975★, last push 2026-09. **verified: yes**
31. **Biderman et al., "Lessons from the Trenches on Reproducible Evaluation of Language Models"**, arXiv:2405.14782, 2024 (EleutherAI). Distils three years of lm-eval-harness experience: sensitivity to setup, comparability, reproducibility, recommendations. Repo EleutherAI/lm-evaluation-harness: 14,504★, last push 2026-11-04. **verified: yes**
32. **Alzahrani et al., "When Benchmarks are Targets: Revealing the Sensitivity of LLM Leaderboards"**, arXiv:2402.01781, 2024. Changing the order of choices or the answer-selection method shifts ranks by up to 8; recommends hybrid scoring. **verified: yes**
33. **Sclar et al., "Quantifying Language Models' Sensitivity to Spurious Features in Prompt Design" (FormatSpread)**, arXiv:2310.11324, 2023. Up to a 76-point spread across formats; recommends reporting ranges. **verified: yes**
34. **Miller, "Adding Error Bars to Evals"**, arXiv:2411.00640, 2024 (Anthropic); companion blog https://www.anthropic.com/research/statistical-approach-to-model-evals. CLT SEs, clustered SEs (over 3× the naive SEs), paired differences (ρ ≈ 0.3–0.7), resampling and power analysis. **verified: yes**
35. **Madaan et al., "Quantifying Variance in Evaluation Benchmarks"**, arXiv:2406.10229, 2024 (Meta). Seed variance and monotonicity; cloze formulation reduces variance for models around 7B; IRT is of limited help. **verified: yes**
36. **Heineman et al., "Signal and Noise"**, arXiv:2508.13144, 2025 (AI2). SNR as a property of a benchmark; perplexity-style metrics, filtering noisy subtasks and checkpoint averaging all improve it. **verified: yes**
37. **Schaeffer, Miranda, Koyejo, "Are Emergent Abilities of LLMs a Mirage?"**, arXiv:2304.15004, 2023. Apparent emergence comes from nonlinear or discontinuous metrics. **verified: yes**
38. **Hugging Face, Open LLM Leaderboard v2 docs: "Scores Normalization"**, https://huggingface.co/docs/leaderboards/open_llm_leaderboard/normalization. Gives the normalisation formula and the GPQA and MuSR worked examples reproduced in §2.11. Blog: "Performances are plateauing, let's make the leaderboard steep again" (Fourrier et al., 2024). **verified: yes** (docs page fetched; blog only partially: seen in search results).

### Contamination, saturation and benchmark quality

39. **Yang et al., "Rethinking Benchmark and Contamination for Language Models with Rephrased Samples"**, arXiv:2311.04850, 2023 (LMSYS). n-gram decontamination is not enough; proposes an LLM-based decontaminator. **verified: yes**
40. **White et al., "LiveBench"**, arXiv:2406.19314, 2024. Frequently updated questions from recent sources, with objective automatic scoring instead of LLM judges. **verified: yes**
41. **Akhtar et al., "When AI Benchmarks Plateau: A Systematic Study of Benchmark Saturation"**, arXiv:2602.16763, 2026. 60 benchmarks, 14 properties; nearly half are saturated; expert curation (not private test data) predicts resilience. **verified: yes**
42. **Ho et al., "A Rosetta Stone for AI Benchmarks"**, arXiv:2512.00193, 2025 (Epoch AI). Puts model capability and benchmark difficulty on one latent scale, used to measure progress and algorithmic efficiency despite saturation. **verified: yes**
43. **Vendrow et al., "Do Large Language Model Benchmarks Test Reliability?"**, arXiv:2502.03461, 2025. Pervasive label errors; "platinum benchmarks". **verified: yes**
44. **Kiela et al., "Dynabench"**, arXiv:2104.14337, 2021. Human-and-model-in-the-loop dynamic benchmark creation as the answer to fast saturation. **verified: yes**

### Classic metric papers and tooling

45. **Papineni et al., "BLEU: a Method for Automatic Evaluation of Machine Translation"**, ACL 2002, https://aclanthology.org/P02-1040/. **verified: yes** (title on the ACL Anthology; the formula is standard).
46. **Lin, "ROUGE: A Package for Automatic Evaluation of Summaries"**, ACL Workshop 2004, https://aclanthology.org/W04-1013/. **verified: yes** (title).
47. **Post, "A Call for Clarity in Reporting BLEU Scores"**, arXiv:1804.08771, 2018. Shows BLEU is parameterised, with differences up to 1.8 between configurations; introduces sacreBLEU. Repo mjpost/sacrebleu: 1,265★, last push 2026-08. **verified: yes**
48. **Zhang et al., "BERTScore"**, arXiv:1904.09675, 2019. Contextual-embedding greedy matching; evaluated on 363 MT and captioning systems. Repo Tiiiger/bert_score: 1,923★. **verified: yes**
49. **Guo et al., "On Calibration of Modern Neural Networks"**, arXiv:1706.04599, 2017. Modern deep networks are miscalibrated; popularised ECE and temperature scaling. **verified: yes**
50. **openai/simple-evals** (4,710★, last push 2026-04), https://github.com/openai/simple-evals. Zero-shot CoT reference implementations of MMLU, GPQA, MATH, SimpleQA and others; bootstrap std. **Deprecation notice (July 2025):** it is no longer updated for new models, but still hosts HealthBench, BrowseComp and SimpleQA. **verified: yes**
51. **Other harnesses, for the "tooling" box:** huggingface/lighteval (2,586★, push 2026-11-18), UKGovernmentBEIS/inspect_ai (3,293★, push 2026-11-20), huggingface/evaluate (2,498★). **verified: yes** (existence, stars and dates only).
52. **Arena-Rank / LMArena methodology** (news.lmarena.ai/arena-rank; PyPI `arena-rank`). Open-source BT plus contextual (style) BT ranking. **verified: partial** (search snippets only; page not opened).

**Total verified sources: 51** (entries tagged yes, counting the grouped entries 9 and 51 as one each). One further entry (52) is partial.

---

## 4. Code patterns from real repos, and teaching-example ideas

### 4.1 Real snippets (exact sources)

**(a) Unbiased pass@k.** `openai/human-eval`, `human_eval/evaluation.py`: see §2.8. The key line is
`return 1.0 - np.prod(1.0 - k / np.arange(n - c + 1, n + 1))`. It equals 1 − C(n−c,k)/C(n,k) because C(n−c,k)/C(n,k) = ∏_{i=n−c+1}^{n} (1 − k/i).

**(b) Log-prob MC prediction variants.** `EleutherAI/lm-evaluation-harness`, `lm_eval/api/task.py` (main, 2026-11):

```python
completion_len = np.array([float(len(i)) for i in choices])
byte_length = np.array([float(len(i.encode("utf-8"))) for i in choices])
...
pred = np.argmax(lls)
pred_norm = np.argmax(lls / completion_len)
pred_byte = np.argmax(lls / byte_length)
...
lls_mutual_info = [ll_c - ll_u for ll_c, ll_u in zip(lls, lls_unconditional, strict=True)]
acc_mutual_info = 1.0 if np.argmax(lls_mutual_info) == gold else 0.0
```

**(c) Corpus-level aggregations.** `lm_eval/api/metrics.py`:

```python
@register_aggregation("perplexity")
def perplexity(items):
    return math.exp(-mean(items))

@register_aggregation("bits_per_byte")
def bits_per_byte(items):
    return -weighted_mean(items) / math.log(2)

def mean_stderr(arr):
    return sample_stddev(arr) / math.sqrt(len(arr))
```

**(d) SQuAD EM / F1 normalisation.** `huggingface/evaluate`, `metrics/squad/compute_score.py` (the "Official evaluation script for v1.1"): `normalize_answer` (lower → remove punctuation → remove articles → fix whitespace), `f1_score` using a `Counter` intersection, and `metric_max_over_ground_truths`.

**(e) Answer extraction.**
- GSM8K, `openai/grade-school-math`, `grade_school_math/dataset.py`: `ANS_RE = re.compile(r"#### (\-?[0-9\.\,]+)")`, with commas stripped and `"[invalid]"` returned on failure.
- simple-evals `common.py`: `ANSWER_PATTERN_MULTICHOICE = r"(?i)Answer[ \t]*:[ \t]*\$?([A-D])\$?"`, plus the template "…The last line of your response should be of the following format: 'Answer: $LETTER'… Think step by step before answering."

**(f) Online Elo vs Bradley–Terry.** `lm-sys/FastChat`, `fastchat/serve/monitor/rating_systems.py`:

```python
def compute_elo(df, k=4.0, base=10.0, init_rating=1000.0, scale=400.0):
    matchups, outcomes, models = preprocess_for_elo(df)
    alpha = math.log(base) / scale
    ratings = np.full(shape=(len(models),), fill_value=init_rating)
    for (model_a_idx, model_b_idx), outcome in zip(matchups, outcomes):
        prob = 1.0 / (1.0 + math.exp(alpha * (ratings[model_b_idx] - ratings[model_a_idx])))
        update = k * (outcome - prob)
        ratings[model_a_idx] += update
        ratings[model_b_idx] -= update
    return {model: ratings[idx] for idx, model in enumerate(models)}
```

and `bt_loss_and_grad` / `fit_bt` (L-BFGS-B over a weighted logistic loss; draws count as 0.5), `scale_and_offset` (anchors `mixtral-8x7b-instruct-v0.1` at 1114), and `compute_bootstrap_bt`.

**(g) SimpleQA aggregation.** `openai/simple-evals`, `simpleqa_eval.py`:
- `is_given_attempted = is_correct + is_incorrect`;
- `accuracy_given_attempted = is_correct / is_given_attempted`;
- `f1 = 2·acc_given_attempted·is_correct / (acc_given_attempted + is_correct)`.

**(h) Bootstrap std.** `openai/simple-evals`, `common.py`, `_compute_stat`: `np.std([np.mean(np.random.choice(values, len(values))) for _ in range(1000)])`.

### 4.2 Runnable, self-contained teaching examples (stdlib / numpy, no API keys)

1. **`pass_at_k.py`**
   - Implement the combinatorial and product forms, assert that they agree, and reproduce the worked numbers (0.9167; 0.4085).
   - Simulate problems with heterogeneous true p and show that the plug-in estimator 1−(1−c/n)^k is biased (exact expectation 0.3485 vs 0.4095 for p = 0.1, n = 10, k = 5), while the unbiased estimator is not.
   - Plot or print pass@k against k.
2. **`mock_mc_eval.py`, log-prob scoring.**
   - A "mock LM" assigns a per-token log-prob of −1.0 to every token, plus a small bonus for the correct token. Long distractors then get lower raw ℓ, so `acc` favours short answers.
   - Show `acc` vs `acc_norm` vs `acc_mutual_info` giving different accuracy on the same 4-choice items.
   - Add a "letter prior" (the model likes "A") to show bias in the MCF/letter formulation, and fix it by permuting choice order (Alzahrani et al.).
3. **`prompt_format_spread.py`.**
   - The mock model's accuracy depends on hash(format string): separators `": "` vs `" - "`, casing, newline vs space.
   - Enumerate about 20 formats and report min, max, mean and the spread, in the spirit of FormatSpread.
   - Show that two mock models can swap rank depending on the format.
4. **`text_metrics.py`.**
   - Stdlib implementations of SQuAD normalisation + EM / F1, corpus BLEU with clipping and BP (plus add-one smoothing), ROUGE-1 / ROUGE-L via LCS, and a toy BERTScore with hand-made numpy embeddings.
   - Reproduce BLEU = 0 vs ROUGE-L = 0.769 for the same pair.
5. **`calibration.py`.** ECE (equal-width and equal-mass), MCE, Brier score, and temperature scaling by grid search on synthetic logits. Reproduce ECE = 0.305 from the table.
6. **`arena_ratings.py`.**
   - Simulate battles from known latent strengths, plus a "length" style effect.
   - Fit online Elo (K = 4) in two random battle orders to show that it depends on order.
   - Fit BT by Newton / gradient descent in numpy, with a bootstrap CI.
   - Add the length covariate (style control) and show the inflated "verbose model" drop in rank.
7. **`error_bars.py`.**
   - Binomial SE and CI.
   - Clustered SE: items are grouped into passages with a random passage effect, so the naive SE underestimates.
   - Paired-difference SE vs unpaired SE for correlated models.
   - A power calculation: how many items are needed to detect a 3 pp gap at 80% power, using n ≈ (z_{α/2}+z_β)²·Var(d)/δ².
8. **`saturation_and_noise.py`.**
   - Simulate a "training run" of checkpoints, score each with accuracy (discrete) and with the log-prob of the correct answer (continuous), and compute an SNR (spread across models / std across neighbouring checkpoints), as in Heineman et al.
   - Show the "emergence" step from an exact-match metric on a multi-token answer compared with smooth per-token accuracy, as in Schaeffer et al.
9. **`contamination_demo.py`.** A "memoriser" mock model that answers perfectly on the original items, and an n-gram overlap detector that catches verbatim copies but misses paraphrased ones (illustrating Yang et al.).
10. **`normalize_scores.py`.** Reproduce the Open LLM Leaderboard examples (GPQA 0.60 → 46.67; MuSR → 35.00).

---

## 5. Pitfalls, debates, open problems, and what practitioners recommend

**Pitfalls**
- *Under-specified protocols.* Few-shot count, template, CoT and extraction regex are often not reported, so "MMLU = X" from two papers may not be comparable (Biderman et al. 2024; Sclar et al. 2023).
- *Choosing a metric by accident.* `acc` vs `acc_norm` vs letter scoring can reorder models (Alzahrani et al. 2024). Using a discontinuous metric can manufacture "emergence" (Schaeffer et al. 2023).
- *Extraction failures counted as model errors.* Strict regexes penalise formatting rather than knowledge. Log or report the extraction-failure rate separately.
- *No error bars.* Gaps of 1–2 pp on a few hundred items are usually inside the noise (Miller 2024). Questions that share a passage need clustered SEs.
- *Mis-estimating pass@k.* Sampling only k completions, or using the plug-in estimator. Mixing temperature settings across k (Codex uses different temperatures for different k; best-k temperature selection is itself optimistic).
- *Contamination.* Static public test sets leak into training data. n-gram filters miss paraphrases (Yang et al. 2023; Zhang et al. 2024).
- *Label noise and ceilings.* About 6.5% errors in MMLU (Gema et al. 2024); a ceiling below 100% means differences near the top are meaningless.
- *Leaderboard gaming and selection bias.* Best-of-N private submissions, and unequal sampling on the Arena (Singh et al. 2025). Verbosity and markdown inflate preference scores (style control; LC-AlpacaEval).
- *Saturation.* Many benchmarks lose discriminative power within one to two years (Akhtar et al. 2026; Ho et al. 2025).
- *Tokenizer dependence.* Token-level perplexity is not comparable across tokenizers; use bits-per-byte.
- *Deprecated reference code.* simple-evals is no longer updated (July 2025). Pin versions and commit hashes of harnesses.

**Debates**
- Log-prob vs generative evaluation: cheap, low-variance signal for base models vs realism for chat or reasoning models.
- Human preference (Arena) as ground truth vs its biases (style, crowd demographics) and gaming. Elo vs BT vs pluralistic rankings.
- Private or held-out tests (FrontierMath, HLE, ARC-AGI private set): contamination resistance vs reproducibility, transparency and trust in the benchmark owner. Akhtar et al. find that expert curation matters more than keeping the test set private.
- Whether IRT or "stitched" latent scales (Rosetta Stone) should replace raw benchmark averages.
- Whether high pass@k at large k shows a capability, given that deployments without a verifier cannot pick the correct sample.

**Open problems**
- Benchmarks that stay hard and uncontaminated (dynamic generation, fresh competitions, private sets that are audited).
- Calibrated, abstention-aware metrics (SimpleQA-style "not attempted"), and measuring "knowing what you know".
- Good reporting standards: a protocol card, CIs, a spread over prompts, and contamination statements.
- Measuring the reliability of evals themselves: SNR (Heineman et al.), test–retest, and agreement between graders.

**Practitioner recommendations (consolidated)**
1. Fix and publish the full protocol: template, shots, CoT, decoding, extraction code and harness version.
2. Report mean ± 95% CI. Use paired tests when comparing models on the same items, and cluster when items are grouped.
3. For sampled metrics, generate n > k samples and use the unbiased pass@k. Report the temperature.
4. Report a range over several prompt formats, or use benchmarks with low prompt sensitivity (MMLU-Pro).
5. For small-model or ablation decisions, prefer continuous metrics (log-prob, bits-per-byte) and benchmarks with high SNR.
6. Use time-stamped or fresh benchmarks for current models (LiveCodeBench after the cutoff date, MathArena, LiveBench), and run contamination probes.
7. Read leaderboards critically: style-controlled ratings, CI overlap, and awareness of selective submission.
8. Audit labels on a sample. Prefer cleaned versions (MMLU-Redux, platinum subsets).

---

## 6. Suggested sub-sections for the book chapter ("Benchmarks and Metrics for LLMs")

1. **What a benchmark score really is.** The five-layer stack (dataset → elicitation → scoring → aggregation → uncertainty), with a diagram.
2. **A tour of the benchmark landscape (2018 → 2026).** A table of benchmark, skill, format, size, metric, status (saturated / active), and contamination resistance. Covers MMLU / MMLU-Pro / MMLU-Redux, GPQA, HellaSwag, ARC, BIG-bench / BBH, HELM, IFEval, GSM8K / GSM1k / GSM-Symbolic, MATH, AIME / MathArena, FrontierMath, HLE, ARC-AGI-1/2, HumanEval, MBPP, LiveCodeBench, TruthfulQA, SimpleQA, Chatbot Arena / Arena-Hard / AlpacaEval.
3. **Scoring generated text.** EM and normalisation, token F1, BLEU (and sacreBLEU signatures), ROUGE, BERTScore. Worked examples and the "BLEU = 0" trap. Code: `text_metrics.py`.
4. **Scoring with probabilities.** Log-likelihood MC (acc, acc_norm, acc_bytes, mutual information), cloze vs letter formulation, perplexity and bits-per-byte. Code: `mock_mc_eval.py`.
5. **Scoring with execution: pass@k.** Derivation of the unbiased estimator, the stable implementation, bias demo, temperature, coverage and repeated sampling. Code: `pass_at_k.py`.
6. **Calibration and abstention.** ECE, MCE, Brier, reliability diagrams, temperature scaling, SimpleQA's three-way grading. Code: `calibration.py`.
7. **Ranking from preferences.** Elo vs Bradley–Terry, bootstrap CIs, style control, length-controlled win rates, the Leaderboard Illusion. Code: `arena_ratings.py`.
8. **Aggregating across tasks.** Macro vs micro averages, chance normalisation (Open LLM Leaderboard v2), why averages hide trade-offs (HELM multi-metric). Code: `normalize_scores.py`.
9. **Error bars and statistical power.** CLT SEs, clustered SEs, paired differences, resampling, power analysis; signal vs noise. Code: `error_bars.py`, `saturation_and_noise.py`.
10. **Prompt sensitivity and protocol choices.** FormatSpread, MC option order, few-shot formatting, CoT vs direct answering. Code: `prompt_format_spread.py`.
11. **When benchmarks break.** Contamination (detection and dynamic benchmarks), label noise, saturation, the emergence "mirage". Code: `contamination_demo.py`.
12. **Checklist: reporting a benchmark result responsibly.** A protocol card template, CI, prompt range, contamination statement, harness version.
13. **Further reading.** The annotated list from §3.
