# Research Dossier 10: Production Evals, RAG Evals and Online Evaluation

Compiled 2026-11-20 for the HTML book *Evaluations for AI: LLMs, Agents and RL Environments*.
Every source in Section 3 was opened (arXiv abstract page, GitHub README/source file or the article itself) and checked for title, authors/org, year, URL and the specific claim attributed. GitHub star counts were read from the GitHub search API on 2026-11-20 and will drift.

---

## 1. Overview: how the parts fit together

Offline benchmarks (Chapters 2-3) tell you what a model *can* do on a fixed distribution. Production evaluation is about what a *system* (prompt + model + retrieval + tools + UI) does on the *live, shifting* distribution of real users, under cost and latency limits. It is a set of layers, each catching failures the others miss. Anthropic's "Demystifying evals for AI agents" (2026) uses the **Swiss Cheese Model** from safety engineering for this: "no single evaluation layer catches every issue."

```
             PRE-DEPLOYMENT                         |                POST-DEPLOYMENT
 ------------------------------------------------   |   -------------------------------------------------
  Unit tests / assertions (format, regex, JSON)     |   Runtime guardrails (input/output rails, blocking)
  Regression eval suite in CI (~100% pass)          |   Online evals: LLM judges / small checkers on a
  Capability eval suite (low pass, hill-climb)      |      sample of production traces (no gold label)
  Component evals (retriever: recall@k, nDCG;       |   Implicit + explicit user signals (accept, retain,
     generator: faithfulness, answer relevance)     |      edit distance, thumbs, re-asks, abandonment)
  Model-swap / prompt-diff comparisons              |   A/B tests & canaries (causal effect on KPIs)
  Dogfooding / internal canary                      |   SLO monitoring: latency p50/p95/p99, cost/req,
                                                    |      error/refusal/429 rates
                                                    |   Drift detection (inputs, embeddings, judge scores)
        ^                                           |                     |
        |______ failures mined from traces become new eval cases ________|   ("data flywheel")
```

How the parts relate:

- **Regression testing in CI** (promptfoo, deepeval, Langfuse experiments, Braintrust) is the "unit test" layer for prompts and models. It runs on every change and blocks merges when scores drop below thresholds.
- **RAG evaluation** splits a pipeline into a **retriever**, judged with IR metrics (recall@k, MRR, nDCG, context precision/recall), and a **generator**, judged on **faithfulness/groundedness** to the retrieved context and **answer relevance**. RAGAS, ARES, RAGChecker and TruLens' "RAG triad" all formalise this split.
- **Hallucination detection** is both an offline metric and an online guardrail: NLI/fact-checker models (AlignScore, MiniCheck, HHEM, Lynx), sampling-consistency methods (SelfCheckGPT, semantic entropy), and claim-decomposition methods (FActScore, RAGChecker).
- **Online evaluation** runs evaluators on live traces. Most traffic has no ground truth, so it relies on reference-free judges, user signals and statistical correction (e.g. prediction-powered inference) to turn noisy judge labels into valid estimates.
- **A/B testing** gives *causal* answers ("did the new model improve retention?") that no offline eval can. Its statistics (power, variance reduction, guardrail metrics) come from the online controlled experiments literature (Kohavi, Deng et al.).
- **Guardrails** are evals that run *inline* and *act*: block, rewrite or escalate. Their precision/recall and added latency must be evaluated themselves.
- **Drift detection** watches for changes in inputs (topic mix, language, length), in the model (silent provider updates, see Chen, Zaharia & Zou 2023) and in judge-score distributions.
- **The flywheel**: OpenAI ("Log everything ... mine your logs for good eval cases"), Vercel ("Any failing prompt ... becomes a permanent part of the test set"), Hamel Husain and Anthropic all describe the same loop. Production failures become eval cases, so **the eval set evolves with the product**.

---

## 2. Key concepts, definitions, formulas and worked examples

### 2.1 Eval types by purpose

| Type | Question | Target pass rate | Cadence |
|---|---|---|---|
| Unit/assertion tests ("Level 1", Husain) | Does output meet hard constraints (valid JSON, no PII, cites a source)? | ~100% | every commit |
| Regression evals (Anthropic) | "Does the agent still handle all the tasks it used to?" | "nearly 100%" | every change / model upgrade |
| Capability evals (Anthropic) | "What can this agent do well?" | starts low | on demand, hill-climb |
| Model & human eval ("Level 2") | Quality on realistic traces, judged by LLM/humans | n/a (score) | set cadence |
| A/B testing ("Level 3") | Causal impact on users/business | n/a (effect size) | significant changes only |

Hamel Husain: "The cost of Level 3 > Level 2 > Level 1. This dictates the cadence." Anthropic warns about **saturation**: "An eval at 100% tracks regressions but provides no signal for improvement." Saturated capability evals should graduate into the regression suite.

### 2.2 Retrieval metrics

Notation: for query q, ranked list r_1..r_K, graded relevance rel_i (0 if not relevant), set R of relevant docs.

- **Precision@k** = |{relevant in top k}| / k
- **Recall@k** = |{relevant in top k}| / |R|
- **Hit rate@k (success@k)** = 1 if any relevant doc is in the top k, else 0. Averaged over queries.
- **Reciprocal rank** RR = 1 / rank of the first relevant doc (0 if none). **MRR** = mean RR over queries.
- **Average Precision** AP = (1/|R|) Σ_k P@k · 1[r_k relevant]. **MAP** = mean AP over queries. RAGAS "context precision" is an AP variant that divides by the number of relevant items *retrieved* (see code in 4.1).
- **DCG@k** = Σ_{i=1..k} g(rel_i) / log2(i+1), with g(rel) = rel (linear) or 2^rel − 1 (exponential, as in the original Järvelin & Kekäläinen / Burges formulation). **nDCG@k** = DCG@k / IDCG@k, where IDCG uses the ideal ordering.

**Worked example** (computed with Python; reproducible): relevant docs d2 (rel 3), d5 (rel 2), d9 (rel 1). System returns top-5 = [d1, d2, d3, d5, d7].
- Precision@5 = 2/5 = 0.40. Recall@5 = 2/3 = 0.667. Hit@1 = 0, Hit@5 = 1. RR = 1/2 = 0.5.
- Linear gain: DCG@5 = 3/log2(3) + 2/log2(5) = 1.893 + 0.861 = **2.754**. IDCG@5 = 3/1 + 2/log2(3) + 1/2 = **4.762**. nDCG@5 = **0.578**.
- Exponential gain: DCG = 7/1.585 + 3/2.322 = 5.709. IDCG = 7 + 3/1.585 + 1/2 = 9.393. nDCG = **0.608**.
- RAGAS-style context precision on binary verdicts [0,1,0,1,0]: (1/2 + 2/4)/2 = **0.50**.

Teaching point: state which gain function and which "k" you use. trec_eval/pytrec_eval and BEIR report nDCG@10 by default for BEIR.

**Where do relevance labels come from in production?** Human labels are scarce, so LLM relevance assessors are common. Thomas et al. (Bing, 2023) built an LLM prompt that agrees with first-party searcher-preference data. UMBRELA (Upadhyay et al., 2024) is an open-source reproduction of that assessor, used in the TREC 2024 RAG Track. The TREC RAG Track also evaluates answers with "nuggets" (AutoNuggetizer, Pradeep et al. 2024).

### 2.3 Generation-side RAG metrics

- **Faithfulness / groundedness** (RAGAS): decompose the answer into atomic statements S, check each against the retrieved context with an LLM/NLI verdict, then
  `faithfulness = |{s in S : supported by context}| / |S|` (the RAGAS code returns NaN when no statements are extracted).
  Example: 5 claims, 4 supported → 0.80.
- **Answer relevance** (RAGAS): generate n questions from the answer and average their embedding cosine similarity to the original question. This penalises incomplete or padded answers, not wrong ones.
- **Context recall** (RAGAS): fraction of claims in the *reference* answer attributable to the retrieved context. Needs a reference.
- **Context relevance / precision**: share of retrieved chunks (or sentences) that are relevant to the question.
- **RAGChecker** (Amazon, 2024) uses claim-level entailment for both directions. It gives overall precision/recall/F1 of response claims against ground-truth claims, retriever metrics (claim recall, context precision) and generator diagnostics (context utilization, noise sensitivity, hallucination, self-knowledge, faithfulness).
- **TruLens "RAG triad"**: context relevance, groundedness, answer relevance (the same three dimensions ARES uses).
- **FActScore** (Min et al., 2023): the share of atomic facts in a long-form generation that a knowledge source supports.

### 2.4 Hallucination detection families

| Family | Needs | Examples | Online-friendly? |
|---|---|---|---|
| NLI / fact-checker vs. context | context + answer | AlignScore (355M), MiniCheck (770M, "GPT-4-level ... 400x lower cost"), Vectara HHEM, Patronus Lynx, RAGTruth-finetuned detectors | Yes (cheap, small models) |
| LLM-as-judge vs. context | context + answer | RAGAS faithfulness, promptfoo `context-faithfulness`, G-Eval | Yes, with sampling |
| Sampling consistency (black box) | k extra samples | SelfCheckGPT, semantic entropy (Farquhar et al., *Nature* 2024) | Costly (k× generation) |
| Claim decomposition + retrieval | knowledge source | FActScore, RAGChecker, FACTS Grounding | Mostly offline |

**Semantic entropy**: sample M answers, cluster them by bidirectional entailment into meaning classes C, then compute SE = −Σ_c p(c) log p(c), with p(c) the summed (or counted) probability of the answers in c. Example: 10 samples, clusters of sizes {7, 2, 1} → SE = −(.7 ln .7 + .2 ln .2 + .1 ln .1) = 0.802 nats. With one cluster of 10, SE = 0. High SE suggests confabulation.

### 2.5 Statistics for online evaluation

**Prediction-powered inference (PPI)** (Angelopoulos et al., 2023; used by ARES). You have N unlabeled production items scored by a judge f and n items with both a human label Y and a judge score. The estimator of the true mean is

  θ̂_PP = (1/N) Σ_{unlabeled} f(X̃_i) − (1/n) Σ_{labeled} (f(X_j) − Y_j)

with variance ≈ Var(f)/N + Var(f − Y)/n. The second term (the "rectifier") removes the judge's bias.
*Example*: the judge says 80.0% of N = 10,000 answers are faithful. On n = 300 human-labeled items the judge says 82% and humans say 76%, so the rectifier is 0.06 and θ̂_PP = 0.80 − 0.06 = **0.74**. Reporting the raw 0.80 would overstate quality by 6 points. The CI width is driven by the 300 labels, but it is narrower than using the 300 labels alone when the judge correlates well with humans.

**A/B test sample size** (two-sided α = 0.05, power 0.8): n per arm ≈ 16 σ² / δ² (Kohavi's rule of thumb). For a thumbs-up rate p = 0.6 (σ² = 0.24) and minimum detectable effect δ = 2 pp: n ≈ 16·0.24/0.0004 = **9,600 per arm** of *feedback-giving* users. Because feedback is sparse, this argues for implicit signals.

**CUPED** (Deng, Xu, Kohavi, Walker, WSDM 2013): Y_cv = Y − θ (X − E[X]), with θ = Cov(X, Y)/Var(X) and X a pre-experiment covariate (e.g. the user's prior-week usage). Var(Y_cv) = Var(Y)(1 − ρ²). With ρ = 0.6, variance drops 36%, so you need 36% fewer users for the same power. Lin & Crespo (2024, arXiv 2410.09027) extend this by combining pre- and in-experiment data.

**Non-determinism**: Atil et al. (2024) show "deterministic" settings (temperature 0, fixed seed) still vary across runs. Repeat evals and report CIs (see Miller, "Adding Error Bars to Evals", 2024, and Chapter 5).

**Guardrail metrics / OEC**: an A/B test should have one overall evaluation criterion plus guardrail metrics that must not regress, such as latency p95, cost/request, refusal rate and safety-filter rate.

### 2.6 User feedback signals

The Microsoft ExP framework (Machmouchi & Gupta, 2023) gives a funnel of: opportunities → prompts sent → responses returned → responses seen → accepts → responses retained. It adds quality signals: edit distance between successive prompts (reformulation), edit distance between response and retained content, and thumbs up/down. It warns that feedback "suffer[s] from low sample size and selection bias." Retention signals are conversation length, conversations per user, days active and new-user retention.

GitHub Copilot shows a metric-choice lesson. Ziegler et al. (2022) found that *acceptance rate* best predicted perceived productivity. The 2025 custom-model post then says optimising acceptance rate "could lead to incorrectly favoring a high volume of simple and short suggestions," so they also optimise **accepted-and-retained characters**. They report +20% accepted-and-retained characters, +12% acceptance rate, 3x throughput and −35% latency. **Goodhart's law in action.**

### 2.7 Cost and latency SLOs

- Latency: **TTFT** (time to first token), **TPOT/ITL** (time per output token), end-to-end latency, tracked at p50/p95/p99 rather than the mean. The ExP framework lists "time to first token render" at multiple percentiles, RPS and tokens per second.
- Cost: tokens in/out per request, cost per *successful* task (failed or truncated responses are "wasted utilization" in ExP; `finish_reason: "length"` counts as truncation). Also count 429 throttles.
- An SLO example: "p95 TTFT < 800 ms and p99 end-to-end < 8 s over 28 days; cost/req < $0.004." Error budget = 1 − SLO target. promptfoo supports `cost` and `latency` assertions in CI (see 4.3).
- Trade-offs: Copilot notes "Higher latency might actually lead to a higher acceptance rate because users might see fewer suggestions total." That is a confound between metrics.

### 2.8 Drift detection

- **Input drift**: PSI = Σ_i (a_i − e_i) ln(a_i/e_i) over bins (topic/intent clusters, length buckets). Example: expected topic shares [.25,.25,.25,.25] and actual [.10,.20,.30,.40] give PSI = **0.228**. Common heuristic thresholds are < 0.1 stable, 0.1-0.25 moderate, > 0.25 major (an industry convention, not a theorem). KS / chi-square tests or embedding-centroid distance (e.g. MMD, cosine of mean embeddings) also work. Evidently implements these for text and embeddings.
- **Model drift**: provider models change silently. Chen, Zaharia & Zou (2023) found GPT-4's prime-identification accuracy went from 84% (March 2023) to 51% (June 2023). Mitigations are pinned model snapshots plus a scheduled "canary" eval.
- **Judge drift**: a judge model upgrade shifts scores even when the system did not change. Version the judge, and re-calibrate it against human labels.
- **Criteria drift** (Shankar et al. 2024): "users need criteria to grade outputs, but grading outputs helps users define criteria." Rubrics evolve with the product.

---

## 3. Annotated source list (41 sources)

### 3.1 RAG evaluation papers

1. **Es, James, Espinosa-Anke, Schockaert. "Ragas: Automated Evaluation of Retrieval Augmented Generation." arXiv 2309.15217 (2023; EACL 2024 demo).** https://arxiv.org/abs/2309.15217. Introduces reference-free RAG metrics (faithfulness, answer relevance, context relevance) computed with LLM prompts, "without having to rely on ground truth human annotations." The basis of the most widely used open-source RAG eval toolkit. *verified: yes*
2. **Saad-Falcon, Khattab, Potts, Zaharia. "ARES: An Automated Evaluation Framework for Retrieval-Augmented Generation Systems." arXiv 2311.09476 (2023; NAACL 2024).** https://arxiv.org/abs/2311.09476. Fine-tunes lightweight LM judges on synthetic data for context relevance, answer faithfulness and answer relevance. Uses **prediction-powered inference** with "only a few hundred human annotations" to get statistically valid estimates. It is the clearest bridge between LLM judges and statistically valid production measurement. *verified: yes*
3. **Ru, Qiu, et al. (Amazon). "RAGChecker: A Fine-grained Framework for Diagnosing Retrieval-Augmented Generation." arXiv 2408.08067 (2024; NeurIPS 2024 D&B).** https://arxiv.org/abs/2408.08067. Claim-level entailment metrics for both retriever and generator, with meta-evaluation showing "significantly better correlations with human judgments than other evaluation metrics." Evaluates 8 RAG systems. *verified: yes*
4. **Yu, Gan, et al. "Evaluation of Retrieval-Augmented Generation: A Survey." arXiv 2405.07437 (2024).** https://arxiv.org/abs/2405.07437. Survey that organises RAG benchmarks and metrics by retrieval/generation targets. A good map for the chapter's taxonomy. *verified: yes (title/authors/date; content skimmed via abstract)*
5. **Chen, Lin, Han, Sun. "Benchmarking Large Language Models in Retrieval-Augmented Generation" (RGB). arXiv 2309.01431 (2023; AAAI 2024).** https://arxiv.org/abs/2309.01431. Tests four RAG abilities: noise robustness, negative rejection, information integration and counterfactual robustness. Good inspiration for targeted RAG test cases. *verified: yes (metadata; abilities from my own knowledge of the paper, so partial on that detail)*
6. **Barnett et al. "Seven Failure Points When Engineering a Retrieval Augmented Generation System." arXiv 2401.05856 (2024).** https://arxiv.org/abs/2401.05856. An experience report from three case studies. Key takeaways: "validation of a RAG system is only feasible during operation" and "robustness ... evolves rather than designed in." Strong motivation for online eval. *verified: yes*
7. **Liu et al. "Lost in the Middle: How Language Models Use Long Contexts." arXiv 2307.03172 (2023; TACL 2024).** https://arxiv.org/abs/2307.03172. Shows performance depends on *where* relevant info sits in the context, being best at the beginning or end. This justifies position-sensitive tests and rank-aware metrics (nDCG) for RAG context. *verified: yes*
8. **Lyu et al. "CRUD-RAG: A Comprehensive Chinese Benchmark for Retrieval-Augmented Generation of LLMs." arXiv 2401.17043 (2024).** https://arxiv.org/abs/2401.17043. A RAG benchmark organised by Create/Read/Update/Delete scenarios. Useful as an example of task-type-stratified RAG evaluation. *verified: yes (metadata)*
9. **Islam, Kannappan, et al. (Patronus AI). "FinanceBench: A New Benchmark for Financial Question Answering." arXiv 2311.11944 (2023).** https://arxiv.org/abs/2311.11944. Open-book financial QA over SEC filings, widely cited for showing RAG setups failing on domain QA. A domain RAG eval exemplar. *verified: yes (metadata)*
10. **Thakur, Reimers, et al. "BEIR: A Heterogenous Benchmark for Zero-shot Evaluation of Information Retrieval Models." arXiv 2104.08663 (2021; NeurIPS D&B).** https://arxiv.org/abs/2104.08663. Classic IR benchmark (nDCG@10 standard), the foundation for retriever evaluation. Repo beir-cellar/beir ★2,334, last push 2025-10-16. *verified: yes*
11. **Thomas, Spielman, Craswell, Mitra (Microsoft/Bing). "Large language models can accurately predict searcher preferences." arXiv 2309.10621 (2023; SIGIR 2024).** https://arxiv.org/abs/2309.10621. Builds an LLM relevance-labelling prompt tuned to agree with first-party user feedback, deployed for large-scale labelling at Bing. Foundational for LLM-labelled retrieval eval. *verified: yes*
12. **Upadhyay, Pradeep, Thakur, Craswell, Lin. "UMBRELA: UMbrela is the (Open-Source Reproduction of the) Bing RELevance Assessor." arXiv 2406.06519 (2024).** https://arxiv.org/abs/2406.06519. An open reproduction of Thomas et al.'s assessor, with repo castorini/umbrela (★61, pushed 2026-04-18). *verified: yes*
13. **Pradeep, Thakur, et al. "Initial Nugget Evaluation Results for the TREC 2024 RAG Track with the AutoNuggetizer Framework." arXiv 2411.09607 (2024).** https://arxiv.org/abs/2411.09607. Nugget-based answer evaluation (atomic information units), automated with LLMs and compared with human assessors. A state-of-the-art community protocol for RAG answer quality. *verified: yes (metadata)*

### 3.2 Hallucination detection / groundedness

14. **Niu et al. "RAGTruth: A Hallucination Corpus for Developing Trustworthy Retrieval-Augmented Language Models." arXiv 2401.00396 (2023; ACL 2024).** https://arxiv.org/abs/2401.00396. Nearly 18,000 RAG responses with word-level hallucination annotations. Shows a fine-tuned small LLM can be competitive with prompt-based detectors. *verified: yes*
15. **Manakul, Liusie, Gales. "SelfCheckGPT: Zero-Resource Black-Box Hallucination Detection for Generative LLMs." arXiv 2303.08896 (2023; EMNLP 2023).** https://arxiv.org/abs/2303.08896. Detects hallucinations by sampling multiple responses and measuring consistency, with no external knowledge base needed. Repo potsawee/selfcheckgpt ★635, last push 2024-06-26. *verified: yes*
16. **Farquhar, Kossen, Kuhn, Gal. "Detecting hallucinations in large language models using semantic entropy." *Nature* 630:625-630 (June 2024), DOI 10.1038/s41586-024-07421-0.** Clusters sampled answers by meaning (bidirectional entailment) before computing entropy, to detect "confabulations." Builds on Kuhn, Gal, Farquhar, "Semantic Uncertainty," arXiv 2302.09664. *verified: yes (via Nature/PMC/OATML listings and the arXiv precursor)*
17. **Min, Krishna, et al. "FActScore: Fine-grained Atomic Evaluation of Factual Precision in Long Form Text Generation." arXiv 2305.14251 (2023; EMNLP 2023).** https://arxiv.org/abs/2305.14251. Atomic-fact decomposition and verification. It is the template for "faithfulness = supported claims / total claims." *verified: yes*
18. **Tang, Laban, Durrett. "MiniCheck: Efficient Fact-Checking of LLMs on Grounding Documents." arXiv 2404.10774 (2024; EMNLP 2024).** https://arxiv.org/abs/2404.10774. Small fact-checkers trained on synthetic data reach "GPT-4-level performance but for 400x lower cost." Introduces the LLM-AggreFact benchmark. Repo Liyan06/MiniCheck ★235. These are ideal online groundedness guardrails. *verified: yes*
19. **Zha, Yang, Li, Hu. "AlignScore: Evaluating Factual Consistency with a Unified Alignment Function." arXiv 2305.16739 (2023; ACL 2023).** https://arxiv.org/abs/2305.16739. A unified alignment model for factual consistency. A common cheap NLI-style groundedness scorer. *verified: yes (metadata)*
20. **Ravi, Mielczarek, et al. (Patronus AI). "Lynx: An Open Source Hallucination Evaluation Model." arXiv 2407.08488 (2024).** https://arxiv.org/abs/2407.08488. An open hallucination-detection LLM for RAG contexts, released with the HaluBench benchmark. *verified: yes (metadata)*
21. **Jacovi, Wang, et al. (Google DeepMind). "The FACTS Grounding Leaderboard." arXiv 2501.03200 (2025).** https://arxiv.org/abs/2501.03200. Benchmarks whether long-form responses are grounded in provided long documents, using multiple LLM judges. *verified: yes (metadata)*
22. **Vectara Hallucination Leaderboard.** https://github.com/vectara/hallucination-leaderboard (★3,328, pushed 2026-11-17). Uses HHEM-2.3 (the commercial model; HHEM-2.1-Open is the open variant) to score summaries of 7,700+ private articles, reporting factual consistency rate, hallucination rate (= 100 − consistency) and answer rate. A good example of a held-out private eval set to avoid overfitting. *verified: yes*
23. **Li et al. "HaluEval: A Large-Scale Hallucination Evaluation Benchmark for LLMs." arXiv 2305.11747 (2023; EMNLP 2023).** https://arxiv.org/abs/2305.11747. Generated-and-annotated hallucinated samples across QA, dialogue and summarisation, for testing whether models recognise hallucinations. *verified: yes (metadata)*

### 3.3 LLM judges, assertions and validators in production

24. **Shankar, Zamfirescu-Pereira, Hartmann, Parameswaran, Arawjo. "Who Validates the Validators? Aligning LLM-Assisted Evaluation of LLM Outputs with Human Preferences." arXiv 2404.12272 (2024; UIST 2024).** https://arxiv.org/abs/2404.12272. EvalGen aligns LLM-generated evaluators (prompts or code) with human grades. Coins **criteria drift**. Essential for "eval sets evolve with the product." *verified: yes*
25. **Shankar, Li, et al. "SPADE: Synthesizing Data Quality Assertions for Large Language Model Pipelines." arXiv 2401.03038 (2024).** https://arxiv.org/abs/2401.03038. Mines prompt edit history to synthesise runtime assertions that flag bad LLM outputs. This is the research basis for "assertions as runtime evals." *verified: yes*
26. **Zheng et al. "Judging LLM-as-a-Judge with MT-Bench and Chatbot Arena." arXiv 2306.05685 (2023).** https://arxiv.org/abs/2306.05685. Canonical study of LLM-judge agreement with humans and biases (position, verbosity, self-enhancement). Relevant whenever online evals use judges. *verified: yes*
27. **Liu, Iter, et al. "G-Eval: NLG Evaluation using GPT-4 with Better Human Alignment." arXiv 2303.16634 (2023).** https://arxiv.org/abs/2303.16634. CoT plus form-filling judge with probability-weighted scores. Used directly by deepeval's `GEval` metric and named in OpenAI's best-practices guide. *verified: yes*

### 3.4 Statistics, experimentation and drift

28. **Angelopoulos, Bates, Fannjiang, Jordan, Zrnic. "Prediction-Powered Inference." arXiv 2301.09633 (2023; *Science* 2023).** https://arxiv.org/abs/2301.09633. Valid confidence intervals that combine a small labeled set with many model predictions. The statistical engine behind ARES and an ideal tool for online judge-based metrics. *verified: yes (metadata)*
29. **Deng, Xu, Kohavi, Walker. "Improving the Sensitivity of Online Controlled Experiments by Utilizing Pre-Experiment Data" (CUPED). WSDM 2013.** https://exp-platform.com/cuped/. Variance reduction via a pre-period covariate. This is standard in A/B platforms (LaunchDarkly, Statsig, etc.). *verified: partial (metadata via exp-platform.com and search results; full text not read)*
30. **Lin & Crespo. "Variance reduction combining pre-experiment and in-experiment data." arXiv 2410.09027 (2024).** https://arxiv.org/abs/2410.09027. Extends CUPED/CUPAC by combining pre- and in-experiment covariates without post-treatment bias. *verified: yes*
31. **Machmouchi & Gupta (Microsoft ExP). "How to Evaluate LLMs: A Complete Metric Framework." Microsoft Research blog, 27 Sep 2023.** https://www.microsoft.com/en-us/research/group/experimentation-platform-exp/articles/how-to-evaluate-llms-a-complete-metric-framework/. A practical metric taxonomy for online LLM experiments: GPU utilisation/cost (tokens, 429s, truncation), Responsible AI (content-filter rates), latency (TTFT, RPS, tokens/s), utility funnel (seen → accepted → retained), edit distance, thumbs, retention. Notes that shadow experiments can't measure user-response metrics. *verified: yes*
32. **Chen, Zaharia, Zou. "How is ChatGPT's behavior changing over time?" arXiv 2307.09009 (2023).** https://arxiv.org/abs/2307.09009. GPT-4 prime-identification accuracy fell from 84% (Mar 2023) to 51% (Jun 2023). This is the canonical evidence for model drift behind a fixed API name. *verified: yes*
33. **Atil, Aykent, et al. "Non-Determinism of 'Deterministic' LLM Settings." arXiv 2408.04667 (2024).** https://arxiv.org/abs/2408.04667. Output variation persists at temperature 0. Motivates repeated runs and CIs in CI/regression evals. *verified: yes (metadata)*
34. **Miller (Anthropic). "Adding Error Bars to Evals: A Statistical Approach to Language Model Evaluations." arXiv 2411.00640 (2024).** https://arxiv.org/abs/2411.00640. CLT-based standard errors, clustered SEs and paired differences for eval comparisons. Directly applicable to "did the new prompt regress?" decisions. *verified: yes (metadata)*
35. **Lu, Hsu, et al. "AgentA/B: Automated and Scalable Web A/B Testing with Interactive LLM Agents." arXiv 2504.09723 (2025).** https://arxiv.org/abs/2504.09723. Simulates A/B tests with LLM agents as users (Amazon.com case study), positioned as a complement to human A/B tests. Useful for the "simulated users before real users" debate. *verified: yes (metadata + search summary)*

### 3.5 Company engineering blogs and practitioner guides

36. **GitHub. "How we evaluate AI models and LLMs for GitHub Copilot" (2025).** https://github.blog/ai-and-ml/generative-ai/how-we-evaluate-models-for-github-copilot/. "We run more than 4,000 offline tests, most of them as part of our automated CI pipeline." Also live internal canary-style evaluations that switch "a number of Hubbers" to a new model, 1,000+ technical chat questions graded partly by an LLM judge, and discussion of acceptance-vs-latency trade-offs. *verified: yes*
37. **GitHub. "The road to better completions: Building a faster, smarter GitHub Copilot with a new custom model" (2025).** https://github.blog/ai-and-ml/github-copilot/the-road-to-better-completions-building-a-faster-smarter-github-copilot-with-a-new-custom-model/. Three layers (offline execution-based benchmarks, pre-production LLM-judge and language-expert evals, production A/B tests). The move from acceptance rate to accepted-and-retained characters. Results: +20%, +12%, 3x throughput, −35% latency. Pair with **Ziegler et al., "Productivity Assessment of Neural Code Completion," arXiv 2205.06537 (2022)**, which found acceptance rate drives perceived productivity. *verified: yes*
38. **Anthropic. "Demystifying evals for AI agents" (Engineering blog, Jan 2026).** https://www.anthropic.com/engineering/demystifying-evals-for-ai-agents. Capability vs. regression evals, saturation, transcript reading, and a comparison table of automated evals, production monitoring, A/B testing, user feedback (thumbs-down is "sparse and self-selected") and human review. Uses the Swiss Cheese model. *verified: yes*
39. **OpenAI. "Evaluation best practices" (API docs).** https://developers.openai.com/api/docs/guides/evaluation-best-practices. Recommends eval-driven development, "Log everything," and continuous evaluation (CE) "to run evals on every change, monitor your app to identify new cases of nondeterminism, and grow the eval set over time." Lists anti-patterns ("Vibe-based evals," "Biased design" that does not reproduce production traffic). Search results indicate the hosted Evals product is being retired (read-only 31 Oct 2026, shutdown 30 Nov 2026), so treat the guidance as platform-independent. *verified: yes (guidance text); partial (deprecation dates, from search snippet only)*
40. **Vercel. "Eval-driven development: Build better AI faster" (2024).** https://vercel.com/blog/eval-driven-development-build-better-ai-faster. Three grading types (code-based, human, LLM-based) applied to v0 (e.g. regex for inline styles vs. Tailwind classes), and the "AI-native flywheel" of evals + data + models + user feedback. *verified: yes*
41. **Braintrust customer story. "How Notion evaluates AI at scale across 70 engineers."** https://www.braintrust.dev/blog/notion. Notion deploys new frontier models in "<24hrs" via regression evals plus frontier evals. Their AI lead's first task was reviewing "the worst customer experiences" from traces. A vendor-published source, so the narrative is promotional. *verified: yes (as a vendor page)*

Additional practitioner reading:
- **Hamel Husain, "Your AI Product Needs Evals" (29 Mar 2024).** https://hamel.dev/blog/posts/evals/. Three levels (unit tests, model & human eval, A/B testing) with cost ordering. Case study "Lucy" (a real-estate assistant). Logging traces and looking at data. *verified: yes*
- **Eugene Yan, "Task-Specific LLM Evals that Do & Don't Work" (2024).** https://eugeneyan.com/writing/evals/. Classification (ROC/PR), summarisation consistency via NLI, copyright regurgitation, toxicity, and "Calibrate your evaluation bar to the level of risk." *verified: yes*
- **Inan et al. "Llama Guard" arXiv 2312.06674 (2023)** and **Rebedea et al. "NeMo Guardrails" arXiv 2310.10501 (2023)**. Input/output safeguard classifiers and programmable rails, i.e. runtime evals. *verified: yes (metadata)*

### 3.6 Open-source tooling (GitHub, star counts on 2026-11-20)

| Repo | Stars | Last push | Role |
|---|---|---|---|
| langfuse/langfuse | 37,647 | 2026-11-20 | Tracing; online LLM-as-judge on "live production traces"; datasets/experiments; annotation queues; CI `RegressionError` (verified from docs) |
| promptfoo/promptfoo | 27,477 | 2026-11-20 | Declarative YAML evals, CI GitHub Action (before/after diff on PRs), `context-faithfulness`/`context-recall`/`context-relevance`, `cost`/`latency` assertions, red teaming |
| comet-ml/opik | 23,457 | 2026-11-20 | Tracing + automated evals + dashboards |
| openai/evals | 19,770 | 2026-04-14 | Eval framework + registry (historic) |
| confident-ai/deepeval | 19,569 | 2026-11-19 | Pytest-style `assert_test`, G-Eval, RAG metrics, `deepeval test run` |
| vibrantlabsai/ragas (formerly explodinggradients/ragas) | 16,384 | 2026-11-14 | RAG metrics, test-set generation. *The explodinggradients path no longer resolved in search; raw README links point to vibrantlabsai, so I infer a rename (partial).* |
| Arize-ai/phoenix | 12,362 | 2026-11-20 | OTel-based observability + evals |
| evidentlyai/evidently | 8,074 | 2026-09-29 | Drift detection, data/LLM quality reports, "100+ metrics" |
| guardrails-ai/guardrails | 7,626 | 2026-11-18 | Validators on LLM output |
| NVIDIA-NeMo/Guardrails | 7,532 | 2026-11-19 | Programmable rails (incl. tool-call validation) |
| truera/trulens | 3,661 | 2026-11-19 | Feedback functions, RAG triad |
| vectara/hallucination-leaderboard | 3,328 | 2026-11-17 | HHEM-based leaderboard |
| beir-cellar/beir | 2,334 | 2025-10-16 | Retrieval benchmark |
| amazon-science/RAGChecker | 1,136 | 2024-12-13 | Claim-level RAG diagnostics |
| braintrustdata/autoevals | 1,085 | 2026-11-19 | Scorer library (LLM + heuristic) |
| stanford-futuredata/ARES | 740 | 2025-03-28 | ARES implementation |
| potsawee/selfcheckgpt | 635 | 2024-06-26 | SelfCheckGPT |
| cvangysel/pytrec_eval | 354 | 2023-10-10 | Python trec_eval bindings |
| Liyan06/MiniCheck | 235 | 2025-08-27 | MiniCheck models |

---

## 4. Code patterns from real repos (exact sources)

### 4.1 RAGAS faithfulness and context precision scoring
Source: `src/ragas/metrics/_faithfulness.py` and `src/ragas/metrics/_context_precision.py`, https://github.com/vibrantlabsai/ragas (main, fetched 2026-11-20)

```python
def _compute_score(self, answers: NLIStatementOutput):
    # check the verdicts and compute the score
    faithful_statements = sum(
        1 if answer.verdict else 0 for answer in answers.statements
    )
    num_statements = len(answers.statements)
    if num_statements:
        score = faithful_statements / num_statements
    else:
        logger.warning("No statements were generated from the answer.")
        score = np.nan
    return score
```
```python
def _calculate_average_precision(self, verdict_list: t.List[int]) -> float:
    cumsum = 0
    numerator = 0.0
    for i, v in enumerate(verdict_list):
        cumsum += v
        if v:
            numerator += cumsum / (i + 1)
    denominator = cumsum + 1e-10
    score = numerator / denominator
    return score
```
Teaching notes: (a) the NaN on zero statements must be handled when aggregating. A refusal like "I don't know" yields no statements, so silently dropping NaNs inflates averages. (b) The denominator is the number of *relevant retrieved* items, not |R|, so this metric does not penalise missing relevant docs. That is context recall's job.

### 4.2 RAGAS custom discrete metric (README quickstart)
Source: https://github.com/vibrantlabsai/ragas README
```python
metric = DiscreteMetric(
    name="summary_accuracy",
    allowed_values=["accurate", "inaccurate"],
    prompt="""Evaluate if the summary is accurate and captures key information.

Response: {response}

Answer with only 'accurate' or 'inaccurate'."""
)
score = await metric.ascore(llm=llm, response="The summary of the text is...")
print(score.value, score.reason)
```

### 4.3 promptfoo: cost/latency SLO assertions and CI on PRs
Source: `site/docs/configuration/expected-outputs/index.md`, https://github.com/promptfoo/promptfoo
```yaml
tests:
  - description: 'Test that the output is cheap and fast'
    vars:
      example: 'Hello, World!'
    assert:
      - type: assert-set
        assert:
          - type: cost
            threshold: 0.001
          - type: latency
            threshold: 200
```
The same doc lists the RAG assertions `context-faithfulness`, `context-recall` and `context-relevance` (each with "default threshold 0.5"), plus shorthand such as `llm-rubric:`, `factuality:`, `is-json` and `similar(0.8):`.

Source: `site/docs/integrations/github-action.md`, which runs a before/after eval when prompts change:
```yaml
on:
  pull_request:
    paths:
      - 'prompts/**'
jobs:
  evaluate:
    runs-on: ubuntu-latest
    permissions:
      pull-requests: write
    steps:
      - name: Run promptfoo evaluation
        uses: promptfoo/promptfoo-action@v1
        with:
          openai-api-key: ${{ secrets.OPENAI_API_KEY }}
          github-token: ${{ secrets.GITHUB_TOKEN }}
          prompts: 'prompts/**/*.json'
          config: 'prompts/promptfooconfig.yaml'
          cache-path: ~/.cache/promptfoo
```
(The cache step is noted as saving "money and time." Caching LLM responses is a key CI cost pattern.)

### 4.4 deepeval: pytest-style regression test
Source: https://github.com/confident-ai/deepeval README
```python
from deepeval.metrics import GEval
from deepeval.test_case import LLMTestCase, SingleTurnParams

def test_case():
    correctness_metric = GEval(
        name="Correctness",
        criteria="Determine if the 'actual output' is correct based on the 'expected output'.",
        evaluation_params=[SingleTurnParams.ACTUAL_OUTPUT, SingleTurnParams.EXPECTED_OUTPUT],
        threshold=0.5
    )
    test_case = LLMTestCase(
        input="What if these shoes don't fit?",
        actual_output="You have 30 days to get a full refund at no extra cost.",
        expected_output="We offer a 30-day full refund at no extra costs.",
    )
    assert_test(test_case, [correctness_metric])
```
Run with `deepeval test run test_ai_agent.py`.

### 4.5 NeMo Guardrails: a deterministic tool-call rail with no model or API key
Source: https://github.com/NVIDIA-NeMo/Guardrails README (develop). The quickstart blocks refunds over $500 with a CEL expression:
```yaml
rails:
  tool_call:
    flows: [tool call validation]
    per_tool:
      issue_refund: [cel check tool call]
  config:
    cel:
      tool_call:
        issue_refund:
          expressions: ["args.amount > 500"]
```
Teaching point: a guardrail is an eval with an action attached. Measure its block rate, false-block rate and added latency.

### 4.6 Langfuse CI gate
Per Langfuse docs (https://langfuse.com/docs/evaluation/overview), experiments can run in CI, where a `RegressionError` fails the job when a score falls below a threshold. I have not quoted code here because I did not fetch a code sample.

### 4.7 Ideas for runnable, self-contained teaching examples (stdlib/numpy, no API keys)

1. **`retrieval_metrics.py`**: implement precision@k, recall@k, hit@k, MRR, AP/MAP and nDCG (linear and exponential gain). Assert they reproduce the worked example (nDCG@5 = 0.578 / 0.608). Compare against pytrec_eval if it is installed.
2. **`toy_rag.py`**: a 30-document corpus, a BM25 retriever in pure Python, and a "generator" that copies sentences from retrieved docs and sometimes injects a fabricated sentence (controlled hallucination rate). Faithfulness is computed by a mock NLI: token-overlap ≥ τ counts as supported. Show that faithfulness drops as the injection rate rises, and that context recall drops as k shrinks.
3. **`ppi_demo.py`**: simulate 10,000 production answers with true faithfulness 0.74 and a biased judge (TPR 0.95, FPR 0.40). Compare the naive judge mean, the human-only mean from 300 labels and the PPI estimate with CI coverage over 1,000 simulations. Learners see that the naive estimate is biased, the human-only CI is wide, and PPI is both unbiased and narrower.
4. **`ab_test_sim.py`**: simulate users with pre-period activity X and outcome Y = a + bX + treatment + noise. Show the power curve, the n ≈ 16σ²/δ² rule, CUPED variance reduction (≈ ρ²), and peeking inflation of the false-positive rate (repeated daily z-tests at α = 0.05 give FPR well above 5%).
5. **`prompt_regression_ci.py`**: a mocked "model" (deterministic function + seeded noise), an eval set as JSONL, assertion functions (JSON validity, required citation, length bound), and a gate that compares the candidate against the baseline with a **paired** bootstrap CI on the per-item score difference. It fails only if the lower CI bound < −margin. Include a `flaky` test showing that run-to-run noise (cf. Atil et al.) triggers false regressions when single runs are compared.
6. **`drift_monitor.py`**: compute PSI between weekly topic histograms (reproduce PSI = 0.228), a KS test on response lengths (implemented with numpy), and an embedding-centroid cosine drift on random vectors with an injected shift. Add a CUSUM/EWMA control chart over daily judge-score means.
7. **`slo_dashboard.py`**: generate log-normal latency samples, compute p50/p95/p99 and error-budget burn rate, cost per *successful* request (exclude truncated/failed outputs), and show that the mean hides tail regressions.
8. **`semantic_entropy.py`**: given mock sampled answers and a mock equivalence function (normalised string or synonym map), cluster them and compute SE (reproduce 0.802 nats for {7, 2, 1}). Threshold to flag confabulations, then compute AUROC against synthetic labels.
9. **`feedback_bias.py`**: simulate users whose probability of giving thumbs feedback depends on satisfaction (unhappy users give feedback more often). Show that the observed thumbs-up rate is biased compared with the true satisfaction rate, and correct it with inverse-propensity weighting when the propensity is known.
10. **`guardrail_eval.py`**: a regex/keyword PII guardrail evaluated on labeled examples (precision/recall/F1). Sweep the threshold to trade off false blocks and misses, and add a latency budget per check.

---

## 5. Pitfalls, debates, open problems and practitioner recommendations

**Pitfalls**
- **Vibe-based evals** and eval sets that don't reflect production traffic (OpenAI's "Biased design"). Build eval sets from logged traces, stratified by intent and including tail cases.
- **Optimising a proxy** (Goodhart). Copilot's acceptance-rate story: short, easy suggestions inflate acceptance. Pair volume metrics with retention/quality metrics.
- **Treating thumbs as ground truth.** Feedback is "sparse and self-selected" (Anthropic) and suffers from "low sample size and selection bias" (Microsoft ExP).
- **Unvalidated LLM judges.** Judges inherit LLM failure modes (Shankar et al.). Calibrate against human labels, report agreement (Cohen's κ, TPR/TNR), and correct estimates with PPI. Version the judge model and prompt.
- **NaN / refusal handling** in RAG metrics (see 4.1). Aggregate abstentions explicitly.
- **Single-run comparisons** under non-determinism give flaky CI. Use repeats, paired tests and margins.
- **Peeking** at A/B tests without sequential correction inflates false positives. Novelty effects are strong for AI features, so run long enough.
- **SUTVA/interference**: shared caches, shared rate limits or collaborative documents can contaminate arms. Shadow experiments can't measure user-response metrics (ExP).
- **Silent provider model changes** (Chen et al. 2023). Pin snapshots and run scheduled canary evals.
- **Retriever metrics with incomplete labels.** Unjudged documents are treated as non-relevant, which penalises novel retrievers. This is a classic TREC pooling issue, and LLM assessors (UMBRELA) help fill holes.
- **Mean latency** hides tails. Use percentiles, and measure TTFT separately for streaming UX.
- **Guardrail cost.** Each inline check adds latency and false blocks. Evaluate guardrails like classifiers.

**Debates**
- *Reference-free (RAGAS-style) vs. reference-based* RAG metrics: reference-free scales to production but can reward confident, irrelevant answers. Reference-based needs curation but anchors correctness.
- *LLM-judge vs. small specialised checkers* (MiniCheck, HHEM, Lynx) for online groundedness: cost and latency against flexibility.
- *Simulated users / agents* (AgentA/B) vs. real A/B tests.
- *How many evals before shipping?* Husain argues for fast iteration and looking at data. Anthropic advises starting early, with even a small set of tasks from real failures.
- *Generic dashboards vs. task-specific metrics*: Eugene Yan and Hamel Husain argue that off-the-shelf metrics "barely correlate" with application-specific performance.

**Open problems**
- Valid inference with judge labels under distribution shift (PPI assumes the labeled set is i.i.d. with production).
- Evaluating multi-turn and agentic RAG, where retrieval is a tool call inside a trajectory.
- Measuring long-term effects (retention, trust) against short-term proxies.
- Detecting subtle hallucinations (misattribution, numeric errors) in long contexts at low cost.
- Criteria drift: formalising how rubrics should version and evolve.
- Benchmark contamination of public RAG sets. Private held-out sets like Vectara's are one response.

**Practitioner recommendations (consensus across sources 36-41 + Husain + Yan)**
1. Log every trace (inputs, retrieved context, outputs, tool calls, latency, tokens, cost, model/prompt versions).
2. Read traces weekly. Do error analysis to pick which evals to build.
3. Use cheap deterministic assertions first, then LLM judges calibrated against humans, then A/B tests for significant changes.
4. Keep a regression suite (~100% pass) and a capability suite (headroom). Promote fixed failures into the regression suite.
5. Gate CI on paired comparisons against the baseline, with response caching.
6. Run online evals on a sampled stream (stratified by risk). Use small fast checkers inline and LLM judges asynchronously.
7. Define SLOs for latency (p95 TTFT), cost per successful task and safety/refusal rates, and treat them as A/B guardrail metrics.
8. Monitor drift in inputs, judge scores and model behaviour. Pin model versions.

---

## 6. Suggested sub-sections for the book chapter

**Chapter: Production Evals, RAG Evaluation and Online Monitoring**

1. **From benchmark to product**: offline vs. online, the Swiss Cheese model, the eval flywheel (Anthropic, OpenAI CE, Vercel, Hamel's three levels).
2. **Regression testing in CI for prompts and models**: assertion tests, regression vs. capability suites, paired comparisons with CIs, flakiness and non-determinism, caching. Tools: promptfoo, deepeval, Langfuse. *Runnable: prompt_regression_ci.py.*
3. **Evaluating retrieval**: precision/recall@k, hit rate, MRR, MAP, nDCG with worked example. Label sources (human, LLM assessors: Bing/UMBRELA). BEIR, pytrec_eval. *Runnable: retrieval_metrics.py.*
4. **Evaluating generation in RAG**: faithfulness, answer relevance, context precision/recall (RAGAS code walk-through), ARES, RAGChecker, TREC nuggets. Failure-point taxonomy (Barnett), position effects (Lost in the Middle), RGB abilities. *Runnable: toy_rag.py.*
5. **Hallucination detection**: NLI checkers (AlignScore, MiniCheck, HHEM, Lynx), sampling methods (SelfCheckGPT, semantic entropy), claim decomposition (FActScore), datasets (RAGTruth, HaluEval, FACTS). *Runnable: semantic_entropy.py.*
6. **Online evaluation on live traffic**: sampling traces, async judges, calibration against humans, PPI-corrected estimates, annotation queues, criteria drift. *Runnable: ppi_demo.py.*
7. **User feedback signals**: explicit vs. implicit, the ExP funnel, edit distance and retention, the Copilot acceptance → retained-characters lesson, selection bias. *Runnable: feedback_bias.py.*
8. **A/B testing LLM features**: OEC and guardrail metrics, power and sample size, CUPED, randomisation unit, novelty, peeking, interference, shadow and canary deployments, simulated users (AgentA/B). *Runnable: ab_test_sim.py.*
9. **Guardrails as runtime evals**: input/output rails (Llama Guard, NeMo Guardrails, Guardrails AI), tool-call validation, measuring guardrail precision/recall/latency. *Runnable: guardrail_eval.py.*
10. **Cost and latency SLOs**: TTFT/TPOT, percentiles, error budgets, cost per successful task, metric trade-offs. *Runnable: slo_dashboard.py.*
11. **Drift detection and evolving eval sets**: input/embedding drift (PSI, KS, MMD), model drift (Chen et al.), judge drift, control charts, turning production failures into eval cases. *Runnable: drift_monitor.py.*
12. **Case studies**: GitHub Copilot (4,000+ offline tests, canaries, A/B, retained characters), Notion (regression + frontier evals, <24h model rollout), Vercel v0 (eval-driven development), Anthropic Claude Code (evals + monitoring + A/B), and the OpenAI best-practices checklist.
13. **Checklist and anti-patterns**: a one-page production eval readiness checklist.
