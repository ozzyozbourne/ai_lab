# Research Dossier 01: Foundations, Taxonomy and Eval-Driven Development

*Prepared 2026-11-20 for the book "Evaluations for AI: LLMs, Agents and RL Environments".*
*Every source in Section 3 was opened (arXiv abstract page, README/raw source file, or article) and checked for title, authors/org, date and the attributed claim, unless it is tagged `verified: partial`.*

---

## 1. Overview of the area and how its parts relate

**What an eval is.** Anthropic's engineering post *Demystifying evals for AI agents* (Jan 9, 2026) gives a working definition: an evaluation ("eval") is a test for an AI system. You give the system an input, then apply grading logic to its output to measure success. Everything else in the field elaborates one of three parts of that sentence:

1. **The input distribution.** Which tasks and datasets you use, and how representative they are. This is where construct validity, contamination and coverage come in.
2. **The system under test.** The model alone, or the model plus prompt, tools, retrieval and agent harness. Anthropic stresses that when you evaluate an agent, you evaluate the harness and the model together.
3. **The grading logic and its aggregation.** Code-based, model-based or human graders, the metrics they produce, and the statistics you use to aggregate and compare them.

**Why evals matter.** Four motivations recur across practitioner and research writing:

- **The engineering loop.** Husain (2024) says unsuccessful AI products almost always share one root cause: "a failure to create robust evaluation systems". Progress depends on cycling quickly between evaluating quality, debugging, and changing the system. Without evals, teams get stuck in what he calls "whack-a-mole", where fixing one failure causes another.
- **Non-determinism.** OpenAI's evaluation best-practices guide makes the same point: generative output varies, so traditional software tests are not enough, and evals become the substitute.
- **Science and decision-making.** Benchmarks track progress and drive choices about training and deployment, so their quality matters (BetterBench; Bean et al. 2025; Weidinger et al. 2025).
- **Safety and governance.** Dangerous-capability and alignment evaluations inform decisions about training, deployment and security (Shevlane et al. 2023).

**How the parts relate (mental map for the chapter).**

```
              WHY: product quality | scientific progress | safety/governance
                                   |
     WHAT is measured  ---------  taxonomy axes  ----------  HOW it is graded
 (capability / alignment /   offline vs online         code-based (assertions, tests,
  safety / cost / latency)   static vs dynamic          exact match, state checks)
                             reference-based vs free    model-based (LLM judge, rubric,
                             unit / regression /         pairwise)
                             capability suites          human (expert, crowd, A/B)
                                   |
                     VALIDITY: does the score support the claim?
      (construct validity, contamination, saturation, Goodhart, judge validity)
                                   |
                  STATISTICS: is the difference real? (SE, CI, paired tests, power)
                                   |
         PROCESS: eval-driven development = error analysis -> targeted evals ->
                  CI regression gates -> production monitoring -> new evals
```

The "process" layer (eval-driven development, error analysis) is how practitioners build application-specific evals. The "validity" and "statistics" layers come mostly from the research literature on benchmarks. A strong foundations chapter connects the two. Product teams face the same validity problems that benchmark builders do (for example, "does my judge measure what my users care about?"), just at smaller scale.

---

## 2. Key concepts, definitions, formulas and worked examples

### 2.1 Core vocabulary (from Anthropic, Jan 2026)

| Term | Definition (paraphrased from the Anthropic post) |
|---|---|
| Task | A single test with defined inputs and success criteria. Also called a problem or test case. |
| Trial | One attempt at a task. Because outputs vary, you run several trials. |
| Grader | Logic that scores some aspect of performance. A task can have several graders, each with several checks. |
| Transcript | The complete record of a trial. Also called a trace or trajectory. |
| Outcome | The final state of the environment after a trial, for example whether a reservation exists in the database. This is what counts, not what the agent *says* it did. |
| Eval harness | Infrastructure that runs evals end to end: tasks, trials, grading and aggregation. |
| Agent harness (scaffold) | The system that lets a model act as an agent. |
| Eval suite | A collection of tasks with a shared broad goal. |

Inspect (UK AISI) names the same concepts in code: `Task(dataset=..., solver=..., scorer=...)`, with `epochs` for repeated trials. lm-evaluation-harness expresses them in YAML: `doc_to_text`, `doc_to_target`, `metric_list` and `filter_list`.

### 2.2 Taxonomy axes

1. **What is measured.**
   - *Capability*: what the system can do. Examples include MMLU (Hendrycks et al. 2020), GPQA and SWE-bench.
   - *Alignment / propensity*: what the system tends to do when it could do otherwise. Shevlane et al. (2023) distinguish "dangerous capability evaluations" from "alignment evaluations", which measure a model's propensity to apply its capabilities for harm.
   - *Safety*: harm and misuse risk. Weidinger et al. (2023) add two layers beyond capability: *human interaction* and *systemic impact*.
   - *Non-functional properties*: cost, latency, calibration, robustness, fairness and efficiency. HELM measures seven metrics: accuracy, calibration, robustness, fairness, bias, toxicity and efficiency. Kapoor et al. (2024) argue that agent evaluations must report cost alongside accuracy.
2. **Offline vs online.**
   - *Offline evals* run on fixed datasets before deployment: CI, regression and benchmarks.
   - *Online evals* run on production traffic: monitoring of sampled traces, A/B tests and user feedback. This is Husain's "Level 3".
   - The Husain/Shankar FAQ draws the line this way: "CI evals protect against known regressions before deployment", while online monitoring finds failures in production traffic and estimates how often they occur. New failure patterns found in production go back into the CI set.
3. **Static vs dynamic benchmarks.**
   - *Static*: a fixed test set, such as MMLU or GSM8K. Static sets saturate and leak into training data.
   - *Dynamic*: the test set keeps changing. Dynabench uses human-and-model-in-the-loop adversarial collection. LiveBench uses frequently updated questions with objective answers. Chatbot Arena uses live crowdsourced pairwise votes. GSM-Symbolic generates questions from templates.
4. **Reference-based vs reference-free.**
   - *Reference-based*: the output is compared to a gold answer, using exact match, ROUGE-L, BLEU/chrF, COMET or a judge with a reference.
   - *Reference-free*: there is no gold answer. Examples are NLI-based factual consistency against the source, COMETKiwi, rubric judges and assertions.
   - applied-llms.org notes a practical consequence: reference-free evals "can be used as guardrails too".
5. **Grader type.** Code-based, model-based or human (Anthropic 2026; OpenAI guide). Scores can be combined in three ways: weighted, binary (every grader must pass) or hybrid.
6. **Granularity / purpose of the suite.**
   - *Unit evals / assertions*: Husain's Level 1. Fast pytest-style checks, for example "no UUIDs leak into output".
   - *Capability evals*: these should start at a low pass rate, "a hill to climb" (Anthropic).
   - *Regression evals*: these should stay near 100%. Capability tasks that reach high pass rates "graduate" into the regression suite.
   - *End-to-end vs step-level*: for agents. Covers tool selection, argument precision and handoff accuracy (OpenAI guide), plus transition-failure matrices (Husain/Shankar FAQ).
7. **Outcome vs process grading.** Anthropic recommends grading outcomes over paths, because rigid step-order checks are brittle. Process checks are still useful for diagnosing failures.

### 2.3 Metrics and estimators (with worked numbers)

All numbers below were computed with a small Python script (`math.comb`), so they can be reproduced in the book.

**(a) Accuracy with a standard error and confidence interval (CLT).**
Miller (2024) and Anthropic's Nov 2024 post treat eval questions as a sample from a "super-population" (a "question universe"). For scores s_i over n items:

- mean = (1/n) Σ s_i
- SE = sqrt( Var(s) / n )
- 95% CI = mean ± 1.96·SE

For Bernoulli scores, Var(s) = p(1−p).

*Example.* With 200 items at 78% accuracy, SE = sqrt(0.78·0.22/200) = 0.0293, so the 95% CI is [72.3%, 83.7%]. A different model scoring 80% on the same 200 items is **not** clearly better.

**(b) Small-n caveat: use Wilson, Bayesian or bootstrap intervals.**
Bowyer, Aitchison & Ivanova (2025) argue that CLT intervals usually underestimate uncertainty dramatically when n is below a few hundred. The Wilson interval for proportion p̂ and z = 1.96 is:

center = (p̂ + z²/2n)/(1 + z²/n),   half-width = z·sqrt(p̂(1−p̂)/n + z²/4n²)/(1 + z²/n)

*Example*, matching Eugene Yan's "Product Evals" scenario. You observe a 3% defect rate on 200 samples against a 5% requirement.

- Normal interval: ±2.4 pp, i.e. [0.6%, 5.4%].
- Wilson interval: [1.4%, 6.4%].
- Both upper bounds exceed 5%, so compliance is not demonstrated.
- With n = 400 the normal margin is ±1.7 pp. Halving the margin requires roughly 4× the samples.

**(c) Clustered standard errors.**
Use these when items share a stimulus, for example several questions about one passage. The variance inflates by the design effect DE ≈ 1 + (m−1)·ICC, where m is the cluster size and ICC the intra-cluster correlation.

- *Example.* With m = 5 and ICC = 0.3, DE = 2.2, so the SE is multiplied by sqrt(2.2) = 1.48.
- Anthropic reports that clustered SEs on popular evals can be more than 3× the naive SEs.
- Inspect implements this as `stderr(cluster="<metadata key>")`.

**(d) Paired differences.**
When two models answer the same items, analyse d_i = s_Ai − s_Bi:

SE_paired = sqrt( (Var_A + Var_B − 2·ρ·SD_A·SD_B)/n )

*Example.* A = 80%, B = 75%, n = 500, correlation ρ = 0.5.

- Unpaired SE of the difference = 0.0264, giving a 95% CI of 5 ± 5.2 pp, which is not significant.
- Paired SE = 0.0187, giving a 95% CI of 5 ± 3.7 pp, which is significant.
- Anthropic reports that between frontier models on popular evals, ρ ≈ 0.3–0.7.

**(e) Power analysis.**
The number of items needed to detect a difference δ (two-sided α = 0.05, power 0.8) is:

n ≈ (1.96 + 0.84)² · Var(d) / δ²

*Example.* To detect δ = 3 pp at the rates in (d), you need about 1,518 items with pairing and about 3,027 without. This is why small eval sets cannot distinguish models that are close.

**(f) Resampling within items.**
Each item's score is its true mean plus noise. Averaging k samples per item (Inspect `epochs`) reduces the within-item variance component. Without chain-of-thought, you can use the token probability of the correct answer (Anthropic 2024).

**(g) pass@k: the unbiased estimator from Chen et al. 2021 (HumanEval).**
Draw n ≥ k samples per problem, of which c are correct:

pass@k = E[ 1 − C(n−c, k)/C(n, k) ]

The numerically stable form in `openai/human-eval` is `1 - np.prod(1 - k/np.arange(n-c+1, n+1))`.

*Example.* With n = 10 and c = 3, pass@1 = 0.30, pass@3 = 0.708 and pass@5 = 0.917.

**(h) pass^k: reliability (τ-bench, Yao et al. 2024).**
pass^k is the probability that **all** k i.i.d. trials succeed. τ-bench's `run.py` estimates it per task as C(c, k)/C(n, k), then averages over tasks.

- *Example.* With n = 10 and c = 3: pass^1 = 0.30, pass^3 = 0.0083, pass^5 = 0. The naive estimate p^k would give 0.027 and 0.0024.
- The Anthropic post illustrates the trend: a 75% per-trial success rate gives pass^3 ≈ 0.42.
- pass@k rises with k, while pass^k falls. Customer-facing agents need pass^k. The τ-bench abstract reports gpt-4o with pass^8 < 25% in retail.

**(i) Judge–human agreement.**
Suppose 100 items are labelled by a human, with 20 human-labelled fails. The judge catches 15 of them (TP), misses 5 (FN), wrongly flags 10 passes (FP) and correctly passes 70 (TN).

- Raw agreement p_o = 0.85.
- Chance agreement p_e = 0.2·0.25 + 0.8·0.75 = 0.65.
- Cohen's κ = (p_o − p_e)/(1 − p_e) = 0.571.
- True positive rate on fails = 0.75; true negative rate = 0.875.

Imbalance makes raw agreement misleading. A judge that always says "pass" on a set with a 5% fail rate has 95% agreement but κ = 0. This is why Husain recommends reporting TPR and TNR separately, and Yan recommends prioritising recall on the fail class. Yan's thresholds: κ 0.4–0.6 is "substantial" and above 0.7 is "excellent". He also notes that human annotators often reach only 0.2–0.3.

**(j) Correcting a judge-estimated pass rate.**
The textbook Rogan–Gladen estimator corrects an observed rate using the judge's measured sensitivity and specificity:

true ≈ (obs + spec − 1)/(sens + spec − 1)

*Example.* With obs = 0.70, sens = 0.90 and spec = 0.80, the corrected rate is 0.714. Prediction-Powered Inference (Angelopoulos et al. 2023) is the principled generalisation: combine many judge labels with a small set of gold labels to get valid confidence intervals. (The Rogan–Gladen formula is standard epidemiology and is stated here as background. It is not taken from one of the cited sources.)

**(k) Task-level metrics practitioners recommend** (Eugene Yan, *Task-Specific LLM Evals that Do & Don't Work*, Mar 2024):

- **Classification:** precision, recall, ROC-AUC and PR-AUC, plus how well the score distributions separate.
- **Summarization:** NLI-based factual consistency, with the source as premise and the summary as hypothesis.
- **Translation:** chrF, BLEURT, COMET and COMETKiwi. BLEU ranked near the bottom at WMT22/23.
- **Copyright regurgitation:** longest common subsequence and edit distance against the source.
- **Toxicity:** Perspective API with p ≥ 0.5.

### 2.4 Construct validity and measurement theory

- **Construct validity.** Bean et al. (2025) define it as the degree to which a benchmark score provides evidence for claims about the target phenomenon. Their systematic review of 445 benchmarks (29 expert reviewers) produced eight recommendations and a checklist.
  - The Oxford Internet Institute's summary of the paper adds statistics that are tagged partial here, because they come from the summary rather than the abstract: only 16% of the benchmarks used statistical tests, about half measure contested abstract phenomena such as "reasoning", and 38% reuse existing benchmarks or exams.
- **Social-science framing.** Wallach et al. (2025) argue that evaluating generative AI is a social-science measurement challenge. They propose a four-level framework: background concept → systematized concept → measurement instrument → instance-level measurements.
- **Limits of "general" benchmarks.** Raji et al. (2021) argue that benchmarks presented as "general" measures of progress have construct-validity problems.
- **BetterBench.** Reuel et al. (2024) assess 24 benchmarks against 46 best practices covering the full benchmark lifecycle. They find most benchmarks do not report statistical significance and are hard to replicate.
- **Benchmark defects.** Label errors put a ceiling on what you can measure. MMLU-Redux (Gema et al. 2024) estimates that 6.49% of MMLU questions contain errors, rising to 57% in the analysed Virology subset. SWE-bench Verified was built by having 93 developers annotate 1,699 samples, keeping a 500-sample subset (OpenAI, Aug 2024; verified: partial).
- **Agentic benchmark validity.** The ABC checklist (Zhu et al. 2025) finds that SWE-bench Verified uses insufficient test cases and that τ-bench counts empty responses as successes. Such issues can over- or under-estimate performance by up to 100% in relative terms.
- **Goodhart's law.** Manheim & Garrabrant (2018) distinguish four variants: regressional, extremal, causal and adversarial. The Leaderboard Illusion (Singh et al. 2025) is a concrete case. Undisclosed private testing and selective disclosure distort the Chatbot Arena rankings: Meta tested 27 private variants before Llama-4, and Google and OpenAI received an estimated 19.2% and 20.4% of the arena's data.

### 2.5 Eval-driven development (EDD) and error analysis

**The loop.** The sources agree on this sequence:

1. Look at data and do error analysis.
2. Define the failure taxonomy.
3. Write targeted evals: assertions first, then validated judges.
4. Change the system.
5. Run the evals in CI.
6. Monitor production.
7. Feed new failures back into the dataset.

**OpenAI guide.** The guide's process is: define objective → collect dataset → define metrics → run and compare → evaluate continuously. Its best practices are "adopt eval-driven development", "design task-specific evals", "log everything", "automate when possible", "evaluations are a continuous process" and "maintain agreement" with human labels. It also gives example targets, such as ROUGE-L ≥ 0.40 plus G-Eval coherence ≥ 80% for summarization.

**Anthropic Claude docs.** Success criteria should be specific, measurable, achievable and relevant. An example criterion: F1 ≥ 0.85 on 10,000 held-out posts, with 99.5% non-toxic outputs and 95% of responses under 200 ms. The docs also advise "prioritize volume over quality": many automatically graded items beat a few hand-graded ones.

**Error analysis (Husain & Shankar FAQ).** Error analysis is "the most important activity in evals":

1. Build a dataset of representative traces.
2. *Open coding*: write free-text notes on the problems you see.
3. *Axial coding*: group the notes into a failure taxonomy and count each category.
4. Iterate until new traces stop revealing new failure types ("theoretical saturation").

Practical guidance from the FAQ:

- Personally annotate at least 30 traces before asking an agent for suggestions, and review at least 100 traces overall.
- Use binary pass/fail labels rather than Likert scales.
- Have a single "benevolent dictator" domain expert be the final voice on quality, for most small and mid-sized teams.
- The authors spent 60–80% of development time on error analysis and evaluation in their projects.

**Critique shadowing (Husain, *Using LLM-as-a-Judge*, Oct 2024).** This is the process for building a judge:

1. Find the principal domain expert.
2. Build a dataset structured by features × scenarios × personas.
3. Have the expert give pass/fail verdicts with written critiques.
4. Fix obvious errors in the system.
5. Iterate the judge prompt, using the critiques as few-shot examples, until it agrees with the expert.
6. Do error analysis.
7. Build specialised judges where needed.

In the Honeycomb example, the judge reached more than 90% agreement with the expert in three iterations.

**Criteria drift (Shankar et al. 2024, EvalGen).** Users need criteria to grade outputs, but grading outputs is how they discover their criteria. Some criteria only emerge after seeing outputs. This challenges any workflow that fixes the rubric in advance, and it is why evaluator development has to be iterative.

---

## 3. Annotated source list (validated)

### A. Research papers

1. **Liang et al., "Holistic Evaluation of Language Models" (HELM).** arXiv:2211.09110, Nov 2022 (TMLR).
   - Builds a taxonomy of scenarios (use cases) and metrics (desiderata).
   - Measures seven metrics (accuracy, calibration, robustness, fairness, bias, toxicity, efficiency) on 16 core scenarios, plus targeted evaluations of 30 models.
   - The canonical argument that evaluation should be multi-metric. Code: stanford-crfm/helm (~2,975 stars, last push Sep 2026).
   - **verified: yes**
2. **Shankar, Zamfirescu-Pereira, Hartmann, Parameswaran, Arawjo, "Who Validates the Validators? Aligning LLM-Assisted Evaluation of LLM Outputs with Human Preferences".** arXiv:2404.12272, Apr 2024 (UIST '24).
   - Presents EvalGen, which generates candidate assertions (code or LLM prompts) and selects them using a small set of human grades.
   - Identifies *criteria drift* and output-dependent criteria.
   - Foundational for "validate your judge" and for iterative criteria design.
   - **verified: yes**
3. **Shankar et al., "SPADE: Synthesizing Data Quality Assertions for LLM Pipelines".** arXiv:2401.03038, Jan 2024.
   - Mines the history of prompt edits to synthesise assertion functions, then selects a minimal set that meets coverage and accuracy requirements.
   - Reduces the number of assertions by 14% and false failures by 21% compared with simpler baselines.
   - The research grounding for Level-1 assertion evals.
   - **verified: yes**
4. **Reuel, Hardy, Smith, Lamparth, Hardy, Kochenderfer, "BetterBench: Assessing AI Benchmarks, Uncovering Issues, and Establishing Best Practices".** arXiv:2411.12990, Nov 2024 (NeurIPS 2024 D&B).
   - Defines 46 best practices across the benchmark lifecycle and scores 24 benchmarks against them.
   - Finds most benchmarks do not report statistical significance and are hard to replicate. Provides a minimum checklist and a living repository at betterbench.stanford.edu.
   - **verified: yes**
5. **Bean et al. (42 authors), "Measuring what Matters: Construct Validity in Large Language Model Benchmarks".** arXiv:2511.04703, Nov 2025 (NeurIPS 2025 D&B).
   - Systematic review of 445 LLM benchmarks by 29 experts, yielding eight recommendations and an operational checklist.
   - The 16% / ~50% / 38% statistics come from the Oxford Internet Institute's summary and were not checked against the full paper.
   - **verified: yes (abstract); partial (statistics)**
6. **Miller, "Adding Error Bars to Evals: A Statistical Approach to Language Model Evaluations".** arXiv:2411.00640, Nov 2024 (Anthropic).
   - Treats evals as experiments drawn from a super-population.
   - Gives formulas for standard errors, comparing two models (paired) and planning experiments (power).
   - The companion Anthropic post (Nov 19, 2024) lists five recommendations: CLT SE, clustered SE, within-question variance reduction, paired differences and power analysis.
   - **verified: yes**
7. **Bowyer, Aitchison, Ivanova, "Position: Don't Use the CLT in LLM Evals With Fewer Than a Few Hundred Datapoints".** arXiv:2503.01747, Mar 2025.
   - Shows that CLT error bars dramatically underestimate uncertainty on small benchmarks.
   - Recommends Bayesian or frequentist alternatives, such as Beta-posterior or Wilson intervals.
   - **verified: yes**
8. **Madaan et al., "Quantifying Variance in Evaluation Benchmarks".** arXiv:2406.10229, Jun 2024 (Meta).
   - Measures seed variance and monotonicity during training across many models.
   - Compares continuous and discrete metrics.
   - **verified: yes**
9. **Heineman et al., "Signal and Noise: A Framework for Reducing Uncertainty in Language Model Evaluation".** arXiv:2508.13144, Aug 2025 (AI2).
   - Defines *signal* (a benchmark's ability to separate better models from worse ones) and *noise* (sensitivity to random variability between training steps).
   - A higher signal-to-noise ratio gives more reliable small-scale decisions. Switching metrics, for example to perplexity, can improve it.
   - **verified: yes**
10. **Polo et al., "tinyBenchmarks: evaluating LLMs with fewer examples".** arXiv:2402.14992, Feb 2024.
    - Shows that 100 curated items can estimate MMLU (14K items) performance accurately.
    - Relevant to eval cost and to IRT-based item selection.
    - **verified: yes**
11. **Chen et al., "Evaluating Large Language Models Trained on Code" (HumanEval / Codex).** arXiv:2107.03374, Jul 2021.
    - Introduces the unbiased pass@k estimator and functional-correctness evaluation.
    - Repo: openai/human-eval (~3,431 stars).
    - **verified: yes (paper and the code in `human_eval/evaluation.py`)**
12. **Yao, Shinn, Razavi, Narasimhan, "τ-bench: A Benchmark for Tool-Agent-User Interaction in Real-World Domains".** arXiv:2406.12045, Jun 2024.
    - Uses LLM-simulated users and grades the outcome by comparing final database state with the goal state.
    - Introduces pass^k. Reports gpt-4o below 50% task success, with pass^8 < 25% in retail.
    - Repo: sierra-research/tau-bench (~1,514 stars, last push Mar 2026).
    - **verified: yes**
13. **Zhu et al., "Establishing Best Practices for Building Rigorous Agentic Benchmarks" (ABC checklist).** arXiv:2507.02825, Jul 2025.
    - Documents task-setup and reward-design flaws in agent benchmarks: SWE-bench Verified has insufficient tests, and τ-bench counts empty responses as successes.
    - These flaws cause up to 100% relative mis-estimation. Applying ABC to CVE-Bench cut overestimation by 33%.
    - **verified: yes**
14. **Kapoor, Stroebl, Siegel, Nadgir, Narayanan, "AI Agents That Matter".** arXiv:2407.01502, Jul 2024.
    - Accuracy-only agent leaderboards produce needlessly costly agents, so cost and accuracy should be optimised jointly.
    - Model evaluation and downstream evaluation have been conflated.
    - Holdout sets are often inadequate, leading to shortcuts and overfitting.
    - Reproducibility is poor.
    - **verified: yes**
15. **Kapoor et al., "Holistic Agent Leaderboard: The Missing Infrastructure for AI Agent Evaluation" (HAL).** arXiv:2510.11977, Oct 2025.
    - Ran 21,730 rollouts across 9 models and 9 benchmarks at a cost of about $40K.
    - Found that higher reasoning effort reduced accuracy in most runs.
    - LLM-aided log inspection found agents searching HuggingFace for the benchmark instead of solving the task. Repo: princeton-pli/hal-harness (~308 stars).
    - **verified: yes**
16. **Zheng et al., "Judging LLM-as-a-Judge with MT-Bench and Chatbot Arena".** arXiv:2306.05685, Jun 2023.
    - Catalogues position, verbosity and self-enhancement biases in LLM judges.
    - Finds GPT-4 judges reach over 80% agreement with humans, the same level as human–human agreement.
    - **verified: yes**
17. **Wang et al., "Large Language Models are not Fair Evaluators".** arXiv:2305.17926, May 2023.
    - Shows position bias: with ChatGPT as the judge, Vicuna-13B beats ChatGPT on 66 of 80 queries just by reordering the answers.
    - Proposes Multiple Evidence Calibration, Balanced Position Calibration and human-in-the-loop calibration.
    - **verified: yes**
18. **Chiang et al., "Chatbot Arena: An Open Platform for Evaluating LLMs by Human Preference".** arXiv:2403.04132, Mar 2024.
    - The canonical dynamic, crowdsourced, pairwise online benchmark.
    - **verified: yes**
19. **Singh et al., "The Leaderboard Illusion".** arXiv:2504.20879, Apr 2025 (Cohere Labs and others).
    - Shows private testing and selective disclosure biasing Arena scores: 27 private Meta variants, and data asymmetries of 19.2% (Google) and 20.4% (OpenAI).
    - Arena-specific data yields up to 112% relative gains on the arena distribution. A Goodhart case study.
    - **verified: yes**
20. **Kiela et al., "Dynabench: Rethinking Benchmarking in NLP".** arXiv:2104.14337, Apr 2021 (NAACL).
    - Human-and-model-in-the-loop adversarial dataset creation, the origin of the "dynamic benchmarking" argument.
    - **verified: yes**
21. **White et al., "LiveBench: A Challenging, Contamination-Limited LLM Benchmark".** arXiv:2406.19314, Jun 2024.
    - Frequently updated questions with objective ground-truth scoring, designed to avoid both contamination and judge bias.
    - **verified: yes**
22. **Raji, Bender, Paullada, Denton, Hanna, "AI and the Everything in the Whole Wide World Benchmark".** arXiv:2111.15366, Nov 2021 (NeurIPS D&B).
    - Argues that benchmarks presented as "general" measures of progress have construct-validity problems.
    - **verified: yes**
23. **Wallach et al., "Position: Evaluating Generative AI Systems Is a Social Science Measurement Challenge".** arXiv:2502.00561, Feb 2025.
    - A four-level measurement framework from background concept to instance-level measurement.
    - Imports validity concepts from the social sciences.
    - **verified: yes**
24. **Weidinger, Raji, Wallach, Mitchell et al., "Toward an Evaluation Science for Generative AI Systems".** arXiv:2503.05336, Mar 2025.
    - Draws lessons from transportation, aerospace and pharmaceuticals: metrics must apply to real-world performance, be refined iteratively, and be backed by evaluation institutions and norms.
    - **verified: yes**
25. **Weidinger et al., "Sociotechnical Safety Evaluation of Generative AI Systems".** arXiv:2310.11986, Oct 2023 (DeepMind).
    - A three-layer framework: capability → human interaction → systemic impact. Surveys existing evaluations and identifies gaps.
    - **verified: yes**
26. **Shevlane et al., "Model evaluation for extreme risks".** arXiv:2305.15324, May 2023.
    - Distinguishes dangerous-capability evaluations from alignment evaluations, which measure propensity.
    - Links both to decisions about training, deployment and security.
    - **verified: yes**
27. **Biderman et al., "Lessons from the Trenches on Reproducible Evaluation of Language Models".** arXiv:2405.14782, May 2024 (EleutherAI).
    - Three years of lm-eval-harness experience: sensitivity to setup, fair comparisons, reproducibility.
    - Writes down the field's tacit knowledge.
    - **verified: yes**
28. **Ribeiro, Wu, Guestrin, Singh, "Beyond Accuracy: Behavioral Testing of NLP Models with CheckList".** arXiv:2005.04118, May 2020 (ACL Best Paper).
    - Software-testing-inspired behavioural tests: a capability × test-type matrix with MFT, INV and DIR tests.
    - Users with CheckList found about 3× as many bugs. The intellectual ancestor of LLM "unit evals".
    - Repo: marcotcr/checklist (~2,051 stars, inactive since Jan 2024).
    - **verified: yes**
29. **Gema et al., "Are We Done with MMLU?".** arXiv:2406.04127, Jun 2024.
    - Estimates that 6.49% of MMLU questions contain errors (57% in the analysed Virology subset).
    - Releases MMLU-Redux.
    - **verified: yes**
30. **Mirzadeh et al., "GSM-Symbolic".** arXiv:2410.05229, Oct 2024 (Apple).
    - Templated variants of GSM8K show notable variance across instantiations of the same question.
    - A robustness and contamination probe for static benchmarks.
    - **verified: yes**
31. **Xu et al., "Benchmark Data Contamination of Large Language Models: A Survey".** arXiv:2406.04244, Jun 2024.
    - A survey of contamination and mitigation strategies.
    - **verified: yes (title/authors/abstract only)**
32. **Manheim & Garrabrant, "Categorizing Variants of Goodhart's Law".** arXiv:1803.04585, Mar 2018.
    - Distinguishes four over-optimisation mechanisms. A theoretical anchor for "metric gaming" and benchmark overfitting.
    - **verified: yes**
33. **Angelopoulos, Bates, Fannjiang, Jordan, Zrnic, "Prediction-Powered Inference".** arXiv:2301.09633, Jan 2023.
    - Valid confidence intervals that combine many model predictions (e.g. from an LLM judge) with a small gold-labelled set.
    - **verified: yes (abstract)**
34. **Kwa et al. (METR), "Measuring AI Ability to Complete Long Software Tasks".** arXiv:2503.14499, Mar 2025.
    - Introduces the 50%-task-completion time horizon, an interpretable metric anchored to human task duration.
    - Reports a horizon of about 50 minutes for Claude 3.7 Sonnet, doubling roughly every 7 months since 2019.
    - **verified: yes**
35. **Phan et al., "Humanity's Last Exam".** arXiv:2501.14249, Jan 2025.
    - A response to saturation: models now exceed 90% on MMLU. HLE has 2,500 expert-written questions.
    - **verified: yes**
36. **Verga et al., "Replacing Judges with Juries" (PoLL).** arXiv:2404.18796, Apr 2024.
    - A panel of diverse smaller judges as an alternative to one large judge.
    - **verified: yes (title/authors)**
37. **Thakur et al., "Judging the Judges".** arXiv:2406.12624, Jun 2024.
    - Evaluates the alignment and vulnerabilities of LLM-as-judge setups.
    - **verified: yes (title/authors)**
38. **Gu et al., "A Survey on LLM-as-a-Judge".** arXiv:2411.15594, Nov 2024.
    - **verified: yes (title/authors)**
39. **Chang et al., "A Survey on Evaluation of Large Language Models".** arXiv:2307.03109, Jul 2023.
    - A broad survey organised around what, where and how to evaluate.
    - **verified: yes (title/authors)**
40. **Eriksson et al., "Can We Trust AI Benchmarks? An Interdisciplinary Review of Current Issues in AI Evaluation".** arXiv:2502.06559, Feb 2025.
    - **verified: yes (title/authors)**

### B. Practitioner articles and documentation

41. **Anthropic Engineering, "Demystifying evals for AI agents"**, Grace, Hadfield, Olivares, De Jonghe, Jan 9, 2026. https://www.anthropic.com/engineering/demystifying-evals-for-ai-agents
    - Supplies the vocabulary in §2.1 and the three grader types.
    - Capability vs regression suites, with tasks graduating from one to the other.
    - pass@k vs pass^k (75% per trial → pass^3 ≈ 42%).
    - Recommends starting with "20-50 simple tasks drawn from real failures" and making tasks unambiguous (two experts would agree on the verdict). A 0% pass rate over many trials usually signals a broken task.
    - Also: balance positive and negative cases, isolate trials, grade outcomes over paths, watch for saturation, and "read the transcripts".
    - **verified: yes**
42. **Hamel Husain, "Your AI Product Needs Evals"**, Mar 29, 2024. https://hamel.dev/blog/posts/evals/
    - Three levels: unit tests, human & model eval, A/B testing.
    - The Rechat "Lucy" case study, the importance of logging traces, and "Remove ALL friction from looking at data".
    - Recommends measuring a judge's precision and recall rather than raw agreement.
    - **verified: yes**
43. **Hamel Husain, "Using LLM-as-a-Judge For Evaluation: A Complete Guide"**, Oct 29, 2024 (updated 2026). https://hamel.dev/blog/posts/llm-judge/
    - Describes critique shadowing (7 steps). The Honeycomb judge reached more than 90% agreement in 3 iterations.
    - Recommends reporting TPR and TNR, and a train/dev/test split for judge validation.
    - **verified: yes**
44. **Hamel Husain & Shreya Shankar, "AI Evals: Everything You Need to Know" (Evals FAQ).** https://hamel.dev/blog/posts/evals-faq/
    - Covers open and axial coding, at least 100 traces, binary over Likert, and the "benevolent dictator".
    - Reports 60–80% of development time spent on evals. Advises against generic metrics and against BERTScore/ROUGE for LLM outputs, and gives a dimension-based recipe for synthetic data.
    - For agents: transition-failure matrices. Also CI vs production monitoring, and RAG via IR metrics (Recall@k, MRR).
    - The page currently shows "published Sep 18, 2026". The FAQ originally appeared in 2025 and is evolving.
    - **verified: yes (content); partial (original publication date)**
45. **Hamel Husain, "A Field Guide to Rapidly Improving AI Products"**, Mar 24, 2025. https://hamel.dev/blog/posts/field-guide/
    - Argues successful teams "barely talk about tools" and obsess over measurement and iteration. Expanded into an O'Reilly report.
    - **verified: partial (search snippets and secondary coverage; the page was not fully read)**
46. **Eugene Yan, "Task-Specific LLM Evals that Do & Don't Work"**, Mar 31, 2024. https://eugeneyan.com/writing/evals/
    - Metrics per task (see §2.3k).
    - Critiques n-gram metrics and G-Eval's reliability. Cites HaluEval showing ChatGPT and Claude 2 at 53.8–58.5% accuracy on distinguishing factual from hallucinated summaries.
    - **verified: yes**
47. **Eugene Yan, "Product Evals in Three Simple Steps"**, Nov 23, 2025. https://eugeneyan.com/writing/product-evals/
    - Three steps: label data, align evaluators, run the harness on every change.
    - Aim for at least 50–100 fails among 200+ samples, with a 75/25 dev/test split.
    - Shows that ±2.4% on 200 samples is too wide (worked example in §2.3b) and gives κ thresholds.
    - Anti-patterns: the "God Evaluator", synthetic-only defects, forced winners. Run pairwise comparisons in both orders and call it a tie if the verdict flips.
    - **verified: yes**
48. **Yan, Bischof, Frye, Husain, Liu, Shankar, "What We've Learned From A Year of Building with LLMs"**, Jun 8, 2024. https://applied-llms.org/
    - Recommends assertion-based unit tests from production samples, pairwise judges with order swapping and ties, and the "intern test".
    - Prefers binary or pairwise labels over Likert. Warns that over-emphasising one eval invokes Goodhart's law, and that needle-in-a-haystack is overused.
    - Reference-free evals can double as guardrails.
    - **verified: yes**
49. **OpenAI, "Evaluation best practices" (API docs).** https://developers.openai.com/api/docs/guides/evaluation-best-practices
    - The EDD process and best practices, plus anti-patterns: generic metrics only, unrepresentative datasets, "vibe-based" evals, ignoring human feedback.
    - Advice by architecture: single-turn, workflows, single-agent (tool selection, argument precision) and multi-agent (handoff accuracy).
    - Edge-case lists. The page notes that the hosted Evals platform is being deprecated: read-only on Oct 31, 2026 and shut down on Nov 30, 2026.
    - **verified: yes**
50. **Anthropic, "A statistical approach to model evaluations"**, Nov 19, 2024. https://www.anthropic.com/research/statistical-approach-to-model-evals
    - Five recommendations. Clustered SEs can be more than 3× naive ones. Between-model correlation on popular evals is 0.3–0.7.
    - **verified: yes**
51. **Anthropic / Claude docs, "Define success criteria and build evaluations".** https://platform.claude.com/docs/en/test-and-evaluate/develop-tests
    - Success criteria should be specific, measurable, achievable and relevant.
    - Three design principles, including "prioritize volume over quality", plus an example eval table and Python exact-match code.
    - Advises using a different model as grader than the one that generated the output.
    - **verified: yes (first ~100K chars of the page)**
52. **OpenAI, "Introducing SWE-bench Verified"**, Aug 13, 2024.
    - 93 developers screened 1,699 samples, each labelled 3 times with the highest-severity label kept, leaving a 500-sample subset.
    - **verified: partial (the page returned 403; facts come from search snippets of openai.com and swebench.com)**

### C. Repositories (star counts via the GitHub search API, 2026-11-20)

| Repo | Stars | Last push | Notes |
|---|---|---|---|
| promptfoo/promptfoo | ~27,474 | 2026-11-20 | Declarative YAML prompt, agent and RAG tests with assertions (`contains`, `icontains`, `llm-rubric`, ...) for CI. Also red teaming. MIT. |
| openai/evals | ~19,769 | 2026-04-14 | Framework plus registry of evals. The README now points to the hosted dashboard, which is being deprecated (see #49). |
| confident-ai/deepeval | ~19,569 | 2026-11-19 | pytest-style `assert_test(test_case, [GEval(...)])`. Apache-2.0. |
| vibrantlabsai/ragas | ~16,384 | 2026-11-14 | RAG/agent evaluation metrics. The `explodinggradients/ragas` path no longer resolves via search, so the repo appears to have moved. **verified: partial**. |
| EleutherAI/lm-evaluation-harness | ~14,504 | 2026-11-04 | YAML task configs (`doc_to_text`, `metric_list`, `filter_list`). MIT. |
| SWE-bench/SWE-bench | ~6,221 | 2026-09-18 | Execution-based agent benchmark. |
| openai/human-eval | ~3,431 | 2026-10-16 | Reference pass@k estimator. |
| UKGovernmentBEIS/inspect_ai | ~3,293 | 2026-11-20 | UK AISI framework: Task/Solver/Scorer, `epochs`, `stderr(cluster=)`. 200+ pre-built evals. MIT. |
| stanford-crfm/helm | ~2,975 | 2026-09-01 | HELM framework. Apache-2.0. |
| marcotcr/checklist | ~2,051 | 2024-01-09 | Behavioural testing. |
| sierra-research/tau-bench | ~1,514 | 2026-03-18 | pass^k implementation. |
| princeton-pli/hal-harness | ~308 | 2026-07-01 | HAL harness. |

**Verified-source count:** 50 sources tagged at least `verified: yes`, 4 tagged partial (#45, #52, ragas, plus the date on #44), and 12 repositories.

---

## 4. Code patterns from real repos, and teaching-example ideas

### 4.1 Real snippets (exact sources)

**(1) Unbiased pass@k.** From `openai/human-eval`, `human_eval/evaluation.py`:
```python
def estimator(n: int, c: int, k: int) -> float:
    """
    Calculates 1 - comb(n - c, k) / comb(n, k).
    """
    if n - c < k:
        return 1.0
    return 1.0 - np.prod(1.0 - k / np.arange(n - c + 1, n + 1))
```

**(2) pass^k.** From `sierra-research/tau-bench`, `tau_bench/run.py` (`display_metrics`):
```python
for k in range(1, num_trials + 1):
    sum_task_pass_hat_k = 0
    for c in c_per_task_id.values():
        sum_task_pass_hat_k += comb(c, k) / comb(num_trials, k)
    pass_hat_ks[k] = sum_task_pass_hat_k / len(c_per_task_id)
```

**(3) Inspect Task, Solver and Scorer.** From `UKGovernmentBEIS/inspect_ai`, `docs/index.qmd`:
```python
from inspect_ai import Task, task
from inspect_ai.dataset import FieldSpec, hf_dataset
from inspect_ai.scorer import model_graded_qa
from inspect_ai.solver import generate

@task
def simpleqa():
    return Task(
        dataset=hf_dataset("codelion/SimpleQA-Verified", split="train",
            sample_fields=FieldSpec(input="problem", target="answer")),
        solver=generate(),
        scorer=model_graded_qa(),
    )
```
Built-in scorers declare their metrics directly. From `src/inspect_ai/scorer/_match.py`: `@scorer(metrics=[accuracy(), stderr()])`. The `stderr` metric (`_metrics/std.py`) takes `cluster: str | None`, the "key from the Sample metadata corresponding to a cluster identifier for computing clustered standard errors".

**(4) Declarative task with answer-extraction filters.** From `EleutherAI/lm-evaluation-harness`, `lm_eval/tasks/gsm8k/gsm8k.yaml`, abridged:
```yaml
task: gsm8k
dataset_path: openai/gsm8k
output_type: generate_until
doc_to_text: "Question: {{question}}\nAnswer:"
doc_to_target: "{{answer}}"
metric_list:
  - metric: exact_match
    aggregation: mean
    ignore_case: true
    regexes_to_ignore: [",", "\\$", "(?s).*#### ", "\\.$"]
generation_kwargs: {do_sample: false, temperature: 0.0}
num_fewshot: 5
filter_list:
  - name: "strict-match"
    filter:
      - function: "regex"
        regex_pattern: "#### (\\-?[0-9\\.\\,]+)"
      - function: "take_first"
  - name: "flexible-extract"
    filter:
      - {function: "regex", group_select: -1, regex_pattern: "(-?[$0-9.,]{2,})|(-?[0-9]+)"}
      - function: "take_first"
```
Teaching point: the *same* model outputs give different scores under "strict" and "flexible" extraction. Answer parsing is part of the measurement instrument (Biderman et al. 2024).

**(5) Assertion-style CI tests.** From `promptfoo/promptfoo`, `examples/getting-started/promptfooconfig.yaml`:
```yaml
prompts:
  - 'Convert the following English text to {{language}}: {{input}}'
tests:
  - vars: {language: French, input: Hello world}
    assert:
      - type: contains
        value: 'Bonjour le monde'
```

**(6) pytest-style LLM test.** From the `confident-ai/deepeval` README:
```python
from deepeval import assert_test
from deepeval.metrics import GEval
from deepeval.test_case import LLMTestCase, SingleTurnParams

def test_case():
    correctness_metric = GEval(name="Correctness",
        criteria="Determine if the 'actual output' is correct based on the 'expected output'.",
        evaluation_params=[SingleTurnParams.ACTUAL_OUTPUT, SingleTurnParams.EXPECTED_OUTPUT],
        threshold=0.5)
    test_case = LLMTestCase(input="What if these shoes don't fit?",
        actual_output="You have 30 days to get a full refund at no extra cost.",
        expected_output="We offer a 30-day full refund at no extra costs.")
    assert_test(test_case, [correctness_metric])
```

**(7) Exact-match accuracy.** From the Anthropic docs, *develop-tests*:
```python
def evaluate_exact_match(model_output, correct_answer):
    return model_output.strip().lower() == correct_answer.lower()
```

### 4.2 Self-contained teaching examples (stdlib/numpy only, mocked models, no API keys)

1. **`mini_harness.py`, a 60-line eval harness.** Use dataclasses `Task(id, input, target, metadata)`, `Trial` and `Grade`. Add a `MockModel` with a seeded `random.Random` that answers correctly with probability p_task, so each task has its own difficulty. Graders: `exact_match`, `regex_extract_number`, `contains_all`. Aggregate accuracy, SE and a 95% CI, and write JSONL logs. This makes task, trial, grader, transcript and harness concrete.
2. **Strict vs flexible extraction.** Run the GSM8K-style regexes from §4.1(4) on 10 mocked outputs, for example "#### 42", "The answer is $42." and "42.0". Show that the accuracy changes with the parser alone.
3. **The statistics toolkit.** Implement `wilson_ci`, `bootstrap_ci`, `clustered_se` (group items by passage id), `paired_diff_test` and `power_n`. Reproduce every worked number in §2.3. Then simulate 2,000 eval runs of two mock models whose true accuracies differ by 2 pp, and show how often n = 100 picks the wrong winner.
4. **pass@k vs pass^k simulator.** Give 50 tasks success probabilities drawn from a Beta distribution, run n = 10 trials each, compute both curves for k = 1..10, and plot them as ASCII or matplotlib. Show the naive-estimator bias (compute p^k from p̂ and compare it with C(c,k)/C(n,k)).
5. **Judge validation lab.** Create 200 synthetic "traces" with hidden ground-truth pass/fail (20% fail). Define a `MockJudge` with configurable TPR, TNR and a position bias, so that in pairwise mode it prefers the first answer with probability 0.6. Compute agreement, Cohen's κ, TPR and TNR. Show the always-pass judge reaching 95% agreement with κ = 0 on an imbalanced set. Show that swap-and-tie removes position bias. Apply the Rogan–Gladen correction, plus a toy PPI-style mean correction using 50 gold labels.
6. **Error-analysis notebook.** Take 40 mocked trace dicts, each with a free-text "open code" note. Write a keyword-based axial-coding function that buckets the notes into a taxonomy, count the buckets with `collections.Counter`, and print a Pareto table. Then build a transition-failure matrix for a mocked 4-stage agent pipeline: parse → retrieve → tool_call → answer.
7. **Regression gate in CI.** Write `test_regressions.py` (pytest or plain `assert`) that loads a JSONL golden set and runs the mocked system. It fails if any regression task fails, or if the lower confidence bound of the capability accuracy drops below a baseline. Demonstrate a "graduated" capability task.
8. **Goodhart / overfitting demo.** "Tune" a mock prompt parameter against a 30-item dev set over 200 random configurations. Show that the dev score of the best configuration is optimistic compared with a held-out test set, which is winner's-curse selection bias. This connects to Kapoor et al. on holdouts and the Leaderboard Illusion on best-of-N private testing.
9. **Contamination probe.** A mock model "memorises" 30% of the items by exact string. Evaluate it on originals and on templated perturbations (GSM-Symbolic-style number swaps), and show the gap.

---

## 5. Pitfalls, debates, open problems, and practitioner recommendations

**Pitfalls**

- **Vibe checks only.** Waiting until after launch, or relying on generic metrics (perplexity, BLEU) or impressions (OpenAI anti-patterns; Husain).
- **Generic off-the-shelf metrics** such as "helpfulness" or "coherence" scores, which create false confidence (Husain & Shankar FAQ). ROUGE and BERTScore are mostly uninformative for LLM outputs, and n-gram metrics are poor even for translation (Yan).
- **Unvalidated LLM judges.** Known biases include position (Wang et al. 2023), verbosity and self-enhancement (Zheng et al. 2023). Raw agreement on imbalanced data misleads, so use TPR/TNR or κ.
- **The "God Evaluator"**: one prompt grading 5–10 dimensions at once (Yan).
- **Likert scales.** They are noisy and hard to calibrate, and annotators drift to the middle value. Prefer binary or pairwise labels (Husain & Shankar; Yan; applied-llms).
- **No error bars.** Ignoring clustering, or comparing models unpaired (Miller 2024). BetterBench finds most benchmarks report no statistical significance. CLT intervals are misleading at small n (Bowyer et al. 2025).
- **Answer-parsing and setup sensitivity.** Prompt format, few-shot count and extraction regex change scores (Biderman et al. 2024).
- **Broken tasks and graders.** Insufficient tests, empty responses counted as success, and 0% pass rates that signal broken tasks (ABC; Anthropic). Label errors in benchmarks (MMLU-Redux; SWE-bench Verified).
- **One-sided evals.** Testing only that a behaviour occurs, not that it is avoided when it should be. "One-sided evals create one-sided optimization" (Anthropic).
- **Shared state between trials**, which produces correlated failures or inflated scores (Anthropic).
- **Overfitting and Goodhart.** Missing holdouts (Kapoor et al. 2024), private best-of-N testing (Singh et al. 2025), contamination (Xu et al. 2024; LiveBench; GSM-Symbolic).
- **Ignoring cost and latency** in agent evaluations (Kapoor et al. 2024; HAL).
- **Saturation.** "An eval at 100% tracks regressions but provides no signal for improvement" (Anthropic). MMLU above 90% prompted HLE.

**Debates**

- **Fixed criteria vs criteria drift.** Can a rubric be specified in advance (OpenAI's "define objective first"), or does it only emerge from looking at outputs (Shankar et al. 2024)? Practitioners resolve this by iterating.
- **Volume vs quality of eval items.** Anthropic's docs advise "prioritize volume over quality" for automated grading. Husain, Shankar and Yan emphasise a small, carefully labelled, balanced set for aligning judges. Both hold, for different purposes.
- **LLM-as-judge reliability.** Zheng et al. report over 80% agreement with humans, matching human–human agreement. Yan and HaluEval show judges failing on factuality. Panels of judges (PoLL) and specialised judges (Prometheus 2) are partial answers.
- **Static vs dynamic benchmarks.** Dynamic benchmarks resist contamination but reduce comparability over time, and crowdsourced dynamics bring their own biases (LiveBench vs Arena; Leaderboard Illusion).
- **Outcome vs process grading** for agents (Anthropic favours outcomes; process checks remain useful for diagnosis).
- **Discrete vs continuous metrics.** Accuracy vs log-probability or perplexity, for signal-to-noise (Madaan et al.; Heineman et al.).
- **Model evals vs downstream application evals.** These are different stakeholders with different needs (Kapoor et al. 2024).

**Open problems**

- Construct validity for abstract constructs such as reasoning, safety and "agency" (Bean et al.; Wallach et al.).
- Evaluation institutions and norms (Weidinger et al. 2025).
- Statistically valid use of cheap judges, through PPI-style inference.
- Eval cost: tiny benchmarks and IRT.
- Agent-benchmark rigor (ABC; HAL) and reward hacking inside eval environments. Agents searching for benchmark answers on HuggingFace is a documented example (HAL).
- Measuring reliability (pass^k) and long-horizon capability (METR time horizon).
- Evaluating multi-turn interactions with simulated users (τ-bench).

**Consolidated practitioner recommendations**

1. Start now and small: 20–50 tasks drawn from real failures (Anthropic). Read at least 100 traces yourself (Husain & Shankar).
2. Do error analysis first (open coding, then axial coding, then counts), and only then write evals for the failure modes you found.
3. Prefer code-based assertions where possible: cheap, deterministic and suitable for CI. Use LLM judges only for what assertions cannot catch. Validate every judge against expert labels on a held-out split, and report TPR/TNR or κ.
4. Use binary pass/fail per dimension, with one evaluator per dimension. For pairwise judgments, swap the order and allow ties.
5. Keep separate suites: capability (low pass rate, a hill to climb), regression (near 100%, run in CI) and online monitoring. Feed production failures back into the suites.
6. Report SE or CI, use paired comparisons and clustered SEs, and plan the sample size with power analysis. Run multiple trials for agents and report pass^k where consistency matters.
7. Balance positive and negative cases, isolate trials, grade outcomes, and guard against shortcuts.
8. Track cost and latency alongside quality.
9. Make looking at data frictionless with custom trace viewers ("Remove ALL friction from looking at data").
10. Treat eval suites like unit tests: owned, versioned and maintained, with contributions from domain experts.

---

## 6. Suggested sub-sections for the book chapter ("Chapter 1: Foundations of Evaluation")

1. **Why evals: the non-determinism problem and the improvement loop.** Covers whack-a-mole, the Rechat example, and the three uses of evals: product, science, safety.
2. **Anatomy of an eval.** Task, trial, grader, transcript, outcome, eval harness and agent harness, with a diagram and the `mini_harness.py` walkthrough.
3. **A taxonomy of evaluations.** What is measured (capability, alignment, safety, non-functional); offline vs online; static vs dynamic; reference-based vs reference-free; unit, regression and capability suites; outcome vs process.
4. **Graders.** Code-based, model-based and human graders, their trade-offs, and how to combine them (weighted, binary, hybrid). A short preview of LLM-as-judge, with a pointer to the dedicated chapter.
5. **Metrics and estimators.** Accuracy and F1, precision and recall on the failure class, pass@k and pass^k with derivations and code, and task-specific metrics.
6. **Statistics for evals.** SE and CI, Wilson and bootstrap intervals, clustered SEs, paired tests, power analysis and resampling (epochs). Lab: "Is model A really better?"
7. **Validity: are you measuring what matters?** Construct validity (Bean et al.; Wallach et al.; Raji et al.); benchmark quality checklists (BetterBench, ABC); label errors (MMLU-Redux, SWE-bench Verified); contamination and saturation; Goodhart's law and the Leaderboard Illusion.
8. **Eval-driven development in practice.** Success criteria, error analysis (open/axial coding, saturation), critique shadowing, criteria drift, synthetic data built from dimensions, and the CI regression gate. Lab: error-analysis notebook and pytest gate.
9. **From offline to online.** Production monitoring, sampled traces, A/B tests, and the feedback loop from production back into CI.
10. **Pitfalls checklist and further reading.** A one-page checklist distilled from §5, and an annotated reading list.

Optional sidebars:
- "pass@k vs pass^k in 3 numbers": with n = 10 and c = 3, pass@3 = 0.71 while pass^3 = 0.008.
- "The always-pass judge": 95% agreement, κ = 0.
- "Why 200 samples can't certify a 5% defect rate".
