# Research Dossier 09: Eval Tooling, Frameworks and GitHub Repositories

*Prepared 2026-11-20 for the book "Evaluations for AI: LLMs, Agents and RL Environments". Every repository row below was checked against the GitHub search API on 2026-11-20 (star counts and `pushed_at` are a snapshot of that day). README and documentation snippets were downloaded from `raw.githubusercontent.com` or the official docs site on the same day. Papers were checked against their arXiv abstract pages (title, first authors, submission date, abstract text).*

Verification legend: **verified: yes** means I opened the primary source (repo README/source, official docs page, or arXiv abstract) and confirmed the specific claim. **verified: partial** means the source exists and the main identity is confirmed but some detail comes from secondary material or a summary.

---

## 1. Overview: how the tooling landscape fits together

Eval tooling sorts into five layers. Most real stacks use one tool from two or three of them.

| Layer | What it does | Representative tools |
|---|---|---|
| **A. Benchmark harnesses (model-centric)** | Run a fixed catalogue of academic benchmarks against a model checkpoint or API, with standard prompts, few-shot setups, answer extraction and metrics. Built for reproducible leaderboard numbers. | EleutherAI `lm-evaluation-harness`, HuggingFace `lighteval`, Stanford `crfm-helm`, OpenAI `simple-evals` (deprecated), OpenCompass, AllenAI OLMES, `bigcode-evaluation-harness`, `lmms-eval` (multimodal) |
| **B. General eval frameworks (task = dataset + solver + scorer)** | Let you write your own evals as code, including multi-turn, tool use, agents and sandboxes. They produce structured logs. | UK AISI **Inspect** (`inspect_ai`) plus `inspect_evals`; OpenAI `evals` (legacy registry) |
| **C. Agent / environment harnesses** | Run an agent inside a container or simulated world, then verify the *outcome state*. These double as RL environments. | SWE-bench harness, tau-bench / tau2-bench, BFCL (`bfcl` CLI), **Harbor** (Terminal-Bench 2.x), Prime Intellect **verifiers** (Environments Hub), MLE-bench, OpenAI `frontier-evals` |
| **D. App-level eval and test libraries (product-centric)** | Unit-test-style assertions and LLM-as-judge metrics for prompts, RAG and agents, often run in CI. | promptfoo, DeepEval, RAGAS, Braintrust `autoevals`, LangChain `openevals`, Phoenix `phoenix-evals` |
| **E. Observability platforms with evals** | Trace production and dev runs, keep versioned datasets, run "experiments" (offline evals), and attach online evaluators to live traffic. | LangSmith, Langfuse, Braintrust, Arize Phoenix, W&B Weave, Comet Opik, MLflow, TruLens |
| **F. Statistical reporting helpers** | Turn per-sample or per-run scores into intervals and comparisons. | `rliable` (archived), the stderr/CI/cluster metrics built into Inspect, pass@k estimators from `human-eval`, pass^k from tau-bench |

How they relate:

- **Model-centric vs. product-centric.** Layers A–C answer "how capable is model/agent X?" Layers D–E answer "did my change to *my* app regress?" Anthropic's agent-evals guide (Jan 2026) separates the **evaluation harness** (runs tasks, records, grades, aggregates) from the **agent harness / scaffold** (lets the model act), and stresses that "evaluating an agent" means evaluating harness and model together.
- **Convergence.** Since 2025 the layers have been merging. `lighteval eval` now uses Inspect as its preferred backend. Harbor is the official harness for Terminal-Bench 2.0, and verifiers ships a Harbor taskset adapter (`verifiers/v1/tasksets/harbor/taskset.py`). Phoenix ships a "phoenix-harbor" skill. The OpenAI Agents SDK sends traces to Weave, Braintrust and Langfuse through trace processors. Promptfoo is "now part of OpenAI" (README, 2026).
- **Evals and RL environments are the same object.** verifiers describes itself as "Our library for RL environments + evals". Harbor says it can "Generate rollouts for RL optimization". SWE-Gym and SWE-smith reuse the SWE-bench harness to produce training data. A well-built eval task with a programmatic verifier *is* a reward function.

A common taxonomy across tools (aligned with the Anthropic guide):

- **Task / sample**: inputs plus success criteria (Inspect `Sample(input, target)`, lm-eval "doc", Harbor task dir, verifiers `TaskData`).
- **Trial / epoch / rollout**: one attempt. Repeating trials gives pass@k and pass^k.
- **Solver / agent / target function**: what produces the output (Inspect `solver`, Braintrust `task`, LangSmith target, Weave `Model.predict`).
- **Grader / scorer / evaluator / metric / reward**: code-based, model-based or human.
- **Transcript / trace / log**: the full record. Inspect `.eval` logs, lm-eval `--log_samples`, verifiers `Trace`, LangSmith/Langfuse traces.
- **Aggregation**: accuracy, mean, stderr, CI, pass@k, IQM.

---

## 2. Key concepts, definitions, formulas and worked examples

### 2.1 Request types in benchmark harnesses (lm-eval)

lm-eval models must implement three request types (`docs/python-api.md`, custom `LM` subclass):

- `loglikelihood(requests)` returns `(logprob, is_greedy)` per (context, continuation). It is used for multiple-choice "cloze" scoring: choose `argmax_i log P(choice_i | context)`, optionally length-normalised (`acc_norm`).
- `loglikelihood_rolling(requests)` gives the full-sequence log-likelihood (perplexity tasks).
- `generate_until(requests)` returns free-form generations, stopped at `until` strings. It is used for GSM8K-style exact match after regex filters.

`output_type` in task YAML selects among `loglikelihood`, `multiple_choice`, `generate_until` and `loglikelihood_rolling`. **Teaching point:** API-only chat models usually cannot give prompt logprobs, so they can only run `generate_until` tasks. That is one reason MMLU numbers differ between harnesses (OLMES, arXiv 2406.08446, documents how "probability normalizations" and "task formulation" change results).

### 2.2 Exact match with normalisation and filters

From the real `gsm8k.yaml`: the metric is `exact_match` with `ignore_case: true` and `regexes_to_ignore: [",", "\\$", "(?s).*#### ", "\\.$"]`. Two filter pipelines produce two reported scores:

- `strict-match`: regex `#### (\-?[0-9\.\,]+)` then `take_first`
- `flexible-extract`: regex `(-?[$0-9.,]{2,})|(-?[0-9]+)` with `group_select: -1` (last match)

Worked example: the generation is `"... so she has $1,200. #### 1,200"` and the target is `"... #### 1200"`. strict-match extracts `1,200`. After removing `,`, the comparison `1200 == 1200` gives 1. If the model forgot the `####` delimiter and wrote "The answer is 1200.", strict-match scores 0 and flexible-extract (last number) scores 1. **The gap between the two numbers measures format-following, not math ability.** This is a good chapter exercise.

### 2.3 pass@k (unbiased estimator, Chen et al. 2021, `human-eval`)

For a problem with `n` samples of which `c` are correct:

```
pass@k = 1 - C(n-c, k) / C(n, k)        (averaged over problems)
```

`human_eval/evaluation.py` implements it in a numerically stable way:

```python
def estimator(n: int, c: int, k: int) -> float:
    """Calculates 1 - comb(n - c, k) / comb(n, k)."""
    if n - c < k:
        return 1.0
    return 1.0 - np.prod(1.0 - k / np.arange(n - c + 1, n + 1))
```

Worked example (n=10, c=3, computed): pass@1 = 0.300, pass@2 = 0.533, pass@5 = 0.917.

### 2.4 pass^k (consistency, Yao et al. 2024, tau-bench)

The probability that **all k** i.i.d. trials succeed, estimated without bias from `n` trials with `c` successes:

```
pass^k = E_task[ C(c, k) / C(n, k) ]
```

From `sierra-research/tau-bench/tau_bench/run.py` (`display_metrics`):

```python
# c from https://arxiv.org/pdf/2406.12045
...
for k in range(1, num_trials + 1):
    sum_task_pass_hat_k = 0
    for c in c_per_task_id.values():
        sum_task_pass_hat_k += comb(c, k) / comb(num_trials, k)
    pass_hat_ks[k] = sum_task_pass_hat_k / len(c_per_task_id)
```

Note that success there means `reward ≈ 1` within 1e-6. Worked example (n=10, c=3): pass^1 = 0.300, pass^2 = 0.067, pass^5 = 0.000. The Anthropic guide's example: a 75% per-trial success rate over 3 trials gives 0.75^3 ≈ 0.42. Inspect has both as epoch reducers: `pass_at_{k}` and `pass_k_{k}` (`--epochs-reducer`; `pass_k(k, value=1.0)` in `inspect_ai.scorer._reducer`).

### 2.5 Standard errors and confidence intervals (Miller 2024; Inspect metrics)

- Mean score: `x̄ = (1/n) Σ s_i`. Standard error: `SE = s / √n` (sample stdev s).
- **Wilson interval** for binary accuracy (Inspect recommends `ci_wilson()` over `ci()` for 0/1 scores). With p̂=42/50=0.84 and z=1.96, Wilson gives **[0.715, 0.917]** and Wald gives [0.738, 0.942]. Wilson is asymmetric and stays inside [0,1].
- **Clustered SE** (questions sharing a passage or category are not independent). `SE_cl = √(Σ_g (Σ_{i∈g} (s_i − x̄))²) / n`. Worked example: 12 scores in 3 clusters of 4: `[1,1,1,1]`, `[0,0,0,0]`, `[1,0,1,0]`. The mean is 0.5, the naive SE is 0.151 and the clustered SE is **0.236**. Inspect: `metrics=[accuracy(), stderr(cluster="category")]`.
- **Paired difference** between two models on the same questions: `d_i = a_i − b_i`, `SE(d̄) = sd(d)/√n`. Worked example with 10 questions, A=`[1,1,0,1,1,0,1,1,1,0]`, B=`[1,0,0,1,1,0,1,0,1,0]`: d̄=0.20, paired SE=0.133, unpaired SE=0.226. Pairing removes question-difficulty variance (Miller's recommendation).
- **Bootstrap SE**: Inspect `bootstrap_stderr(num_samples=1000)`. rliable uses *stratified* bootstrap across tasks and runs.

### 2.6 Robust aggregates for RL and multi-task (Agarwal et al. 2021, `rliable`)

- **IQM (interquartile mean)**: drop the bottom and top 25% of the pooled run×task scores and take the mean. Example over 8 scores `[0.1,0.2,0.4,0.5,0.55,0.6,0.7,0.9]`: IQM = mean(0.4,0.5,0.55,0.6) = **0.5125** (mean 0.494, median 0.525).
- **Optimality gap**: the amount by which the algorithm falls short of a normalised target score γ (default 1), `E[max(γ − x, 0)]`.
- **Probability of improvement** `P(X > Y)`: computed per task with a Mann-Whitney-style statistic, then averaged.
- **Performance profiles**: the fraction of runs with score above τ, plotted against τ.

### 2.7 LLM-as-judge in tooling

Most libraries in layer D wrap a judge prompt and a parser:

- **G-Eval** (arXiv 2303.16634): CoT plus form-filling, with scores weighted by token probabilities. DeepEval's `GEval(name, criteria, evaluation_params, threshold)` is named after it.
- **Classifier-style judge**: Phoenix `create_classifier(choices={"helpful":1.0,"not_helpful":0.0})`, RAGAS `DiscreteMetric(allowed_values=[...])`, openevals `create_llm_as_judge(prompt=CORRECTNESS_PROMPT, model=...)` returning `{'key','score','comment'}`.
- Known biases (MT-Bench paper, arXiv 2306.05685): position, verbosity and self-enhancement. Agreement with humans was above 80% for GPT-4 judges, about the same as human–human agreement.

### 2.8 Trajectory matching (agents)

openevals `create_trajectory_match_evaluator(trajectory_match_mode=...)` has four modes:

- `strict`: same tool calls in the same order
- `unordered`: same tool calls in any order
- `subset`: the output's tool calls are a subset of the reference
- `superset`: the output's tool calls are a superset of the reference

Strict mode tolerates different message *content* ("SF" vs "San Francisco"), but not different tool calls. BFCL instead checks function calls by **AST matching** (the function name, required params, and that each value is in an allowed set), plus state-based checking for multi-turn.

### 2.9 Outcome-based verification (agent harnesses)

- SWE-bench: apply the model's patch and run the repo's FAIL_TO_PASS and PASS_TO_PASS tests in Docker. The instance is resolved when all of them pass.
- Harbor: `tests/test.sh` writes `/logs/verifier/reward.txt` (a single number) or `/logs/verifier/reward.json` (multiple metrics, e.g. `{"accuracy": 0.95, "runtime_sec": 1.2}`).
- verifiers: `@vf.reward async def ...(self, trace|runtime) -> float`, optionally in an **isolated** grading sandbox (`ScoringConfig(mode="isolated")`) so the agent cannot tamper with tests.
- tau-bench: compare the final database state to the goal state, and check required outputs.

---

## 3. Annotated source list (validated)

### 3a. Repositories (snapshot 2026-11-20 via GitHub search API)

| # | Repo | Stars | Last push | License | Notes |
|---|---|---|---|---|---|
| R1 | [EleutherAI/lm-evaluation-harness](https://github.com/EleutherAI/lm-evaluation-harness) | 14,504 | 2026-11-04 | MIT | |
| R2 | [UKGovernmentBEIS/inspect_ai](https://github.com/UKGovernmentBEIS/inspect_ai) | 3,293 | 2026-11-20 | MIT | |
| R3 | [UKGovernmentBEIS/inspect_evals](https://github.com/UKGovernmentBEIS/inspect_evals) | 750 | 2026-11-19 | MIT | maintained by Generality Labs |
| R4 | [openai/evals](https://github.com/openai/evals) | 19,770 | 2026-04-14 | custom (NOASSERTION) | |
| R5 | [openai/simple-evals](https://github.com/openai/simple-evals) | 4,710 | 2026-04-22 | MIT | deprecated Jul 2025 |
| R6 | [stanford-crfm/helm](https://github.com/stanford-crfm/helm) | 2,975 | 2026-09-01 | Apache-2.0 | |
| R7 | [huggingface/lighteval](https://github.com/huggingface/lighteval) | 2,586 | 2026-11-18 | MIT | |
| R8 | [promptfoo/promptfoo](https://github.com/promptfoo/promptfoo) | 27,477 | 2026-11-20 | MIT | now part of OpenAI |
| R9 | [confident-ai/deepeval](https://github.com/confident-ai/deepeval) | 19,569 | 2026-11-19 | Apache-2.0 | |
| R10 | [vibrantlabsai/ragas](https://github.com/vibrantlabsai/ragas) | 16,384 | 2026-11-14 | Apache-2.0 | the old `explodinggradients/ragas` path no longer resolves via search; the org moved |
| R11 | [openai/openai-agents-python](https://github.com/openai/openai-agents-python) | 30,777 | 2026-11-20 | MIT | |
| R12 | [langfuse/langfuse](https://github.com/langfuse/langfuse) | 37,647 | 2026-11-20 | custom (MIT core + EE) | |
| R13 | [braintrustdata/autoevals](https://github.com/braintrustdata/autoevals) | 1,085 | 2026-11-19 | MIT | |
| R14 | [Arize-ai/phoenix](https://github.com/Arize-ai/phoenix) | 12,362 | 2026-11-20 | custom (Elastic-2.0 style) | |
| R15 | [wandb/weave](https://github.com/wandb/weave) | 1,151 | 2026-11-19 | Apache-2.0 | |
| R16 | [PrimeIntellect-ai/verifiers](https://github.com/PrimeIntellect-ai/verifiers) | 4,797 | 2026-11-20 | MIT | `willccbb/verifiers` no longer resolves; created by Will Brown |
| R17 | [google-research/rliable](https://github.com/google-research/rliable) | 876 | 2024-08-12 | Apache-2.0 | **archived** |
| R18 | [SWE-bench/SWE-bench](https://github.com/SWE-bench/SWE-bench) | 6,222 | 2026-09-18 | MIT | |
| R19 | [sierra-research/tau-bench](https://github.com/sierra-research/tau-bench) | 1,514 | 2026-03-18 | MIT | |
| R20 | [sierra-research/tau2-bench](https://github.com/sierra-research/tau2-bench) | 2,487 | 2026-11-10 | MIT | |
| R21 | [ShishirPatil/gorilla](https://github.com/ShishirPatil/gorilla) (BFCL under `berkeley-function-call-leaderboard/`) | 13,080 | 2026-10-17 | Apache-2.0 | |
| R22 | [harbor-framework/harbor](https://github.com/harbor-framework/harbor) | 7,272 | 2026-11-20 | Apache-2.0 | |
| R23 | [harbor-framework/terminal-bench](https://github.com/harbor-framework/terminal-bench) | 1,103 | 2026-11-20 | Apache-2.0 | `terminal-bench-1` has 2,623 stars |
| R24 | [langchain-ai/openevals](https://github.com/langchain-ai/openevals) | 1,257 | 2026-11-18 | MIT | (`langsmith-sdk` was archived 2026-10-16; its README says the SDK moved) |
| R25 | [openai/human-eval](https://github.com/openai/human-eval) | 3,431 | 2026-10-16 | MIT | |
| R26 | [open-compass/opencompass](https://github.com/open-compass/opencompass) | 7,606 | 2026-11-18 | Apache-2.0 | |
| R27 | [EvolvingLMMs-Lab/lmms-eval](https://github.com/EvolvingLMMs-Lab/lmms-eval) | 4,501 | 2026-11-18 | custom | |
| R28 | [mlflow/mlflow](https://github.com/mlflow/mlflow) | 28,903 | 2026-11-20 | Apache-2.0 | |
| R29 | [comet-ml/opik](https://github.com/comet-ml/opik) | 23,457 | 2026-11-20 | Apache-2.0 | |
| R30 | [truera/trulens](https://github.com/truera/trulens) | 3,661 | 2026-11-19 | MIT | |
| R31 | [allenai/olmes](https://github.com/allenai/olmes) | 413 | 2026-03-24 | Apache-2.0 | |
| R32 | [SWE-agent/SWE-agent](https://github.com/SWE-agent/SWE-agent) | 20,835 | 2026-11-16 | MIT | |
| R33 | [openai/mle-bench](https://github.com/openai/mle-bench) | 1,801 | 2026-04-24 | custom | |
| R34 | [openai/frontier-evals](https://github.com/openai/frontier-evals) | 1,345 | 2026-10-12 | MIT | |
| R35 | [METR/vivaria](https://github.com/METR/vivaria) | 145 | 2026-10-07 | MIT | **archived** |
| R36 | [huggingface/evaluate](https://github.com/huggingface/evaluate) | 2,498 | 2026-11-16 | Apache-2.0 | metric library |
| R37 | [bigcode-project/bigcode-evaluation-harness](https://github.com/bigcode-project/bigcode-evaluation-harness) | 1,063 | 2025-07-22 | Apache-2.0 | slowing |

### 3b. Annotated entries

**S1. EleutherAI lm-evaluation-harness** (R1). *verified: yes.*
This is the de facto open harness for few-shot and zero-shot benchmark evaluation of base and instruct models. It powered the HF Open LLM Leaderboard. Recent changes from the README news: a CLI refactor with subcommands `run`, `ls`, `validate` and `--config` YAML (2025/12); a lighter base install where backends are extras, e.g. `pip install "lm_eval[hf]"`, `[vllm]`, `[api]` (2025/12); a plugin system through `lm_eval.*` entry points (2026/09); and a `think_end_token` arg for stripping reasoning traces (2025/07). Tasks are declared in YAML (`dataset_path`, `doc_to_text`, `doc_to_target`, `doc_to_choice`, `output_type`, `metric_list`, `filter_list`, `generation_kwargs`, `num_fewshot`) and run with `--include_path`. A `dummy` model is registered in `lm_eval/models/dummy.py`: it returns random loglikelihoods and the string `"lol"` for generations, which makes it useful for teaching without a GPU. The README advises `--limit 10` with `--log_samples` to inspect answer extraction before full runs on chat APIs.

**S2. Inspect (`inspect_ai`)**, UK AI Security Institute (R2). *verified: yes.*
A Python framework in which an eval is a `Task(dataset, solver, scorer)`, optionally with `sandbox="docker"` for agentic tasks. It ships built-in agents (`react()`), tools (`bash()`, `todo_write()`, web search, computer use), scorers (`includes`, `match`, `pattern`, `answer`, `exact`, `f1`, `choice`, `math`, `model_graded_qa`, `model_graded_fact`, perplexity scorers), and statistics metrics (`accuracy`, `mean`, `stderr(cluster=...)`, `bootstrap_stderr`, `ci`, `ci_wilson`, `grouped`). Epochs and reducers include `pass_at_{k}`, `pass_k_{k}`, `at_least_{n}` and `mode`. The log viewer is `inspect view`, and the docs site says more than 200 pre-built evals are available. A `mockllm/model` provider (`src/inspect_ai/model/_providers/mockllm.py`) returns `"Default output from mockllm/model"` or scripted `custom_outputs`, which suits offline teaching. The docs publish `llms.txt` and `llms-full.txt` for coding agents.

**S3. inspect_evals** (R3). *verified: yes.*
A library of evaluations built on Inspect, installable with `pip install inspect-evals`. The README says it is maintained by Generality Labs (a London nonprofit), founded in 2024 with contributions from UK AISI, Arcadia Impact and the Vector Institute. PRs now come only from pre-approved contributors. Bug reports should attach `.eval` logs. It is a good source of reference implementations of popular benchmarks such as GPQA, SWE-bench and GAIA in one consistent API.

**S4. OpenAI evals** (R4). *verified: yes.*
The original (2023) "framework for evaluating LLMs and LLM systems and an open-source registry" of evals. The registry data is stored in Git-LFS. Evals are built from YAML templates and model-graded YAML specs, with a "Completion Function Protocol" for chains and agents. The README now points users to the OpenAI Dashboard Evals product and says they are "currently not accepting evals with custom code". The repo matters historically and as a dataset source, not as an actively developed framework (last push April 2026).

**S5. OpenAI simple-evals** (R5). *verified: yes.*
A lightweight reference implementation of MMLU, MATH, GPQA, DROP, MGSM, HumanEval, SimpleQA, BrowseComp and HealthBench. Its main methodological statement: it emphasises "the *zero-shot, chain-of-thought* setting, with simple instructions", arguing that few-shot and role-play prompts are "carryovers from evaluating *base models*". The July 2025 deprecation notice says it will no longer be updated for new models, but it keeps hosting HealthBench, BrowseComp and SimpleQA. Use it as a minimal readable code base for teaching.

**S6. HELM (`crfm-helm`)** (R6) and the HELM paper (P2). *verified: yes.*
Install with `pip install crfm-helm`. Run `helm-run --run-entries mmlu:subject=philosophy,model=openai/gpt2 --suite my-suite --max-eval-instances 10`, then `helm-summarize --suite my-suite` and `helm-server --suite my-suite`. The paper (Liang et al., arXiv 2211.09110, Nov 2022) introduced the multi-metric approach: 7 metrics (accuracy, calibration, robustness, fairness, bias, toxicity, efficiency) over 16 core scenarios, plus 26 targeted scenarios, giving 42 scenarios across 30 models.

**S7. lighteval (Hugging Face)** (R7). *verified: yes.*
The README lists 1000+ tasks, with backends for `accelerate`, `vllm`, `sglang`, `nanotron`, `endpoint` (TGI, inference endpoints, LiteLLM, inference providers) and `custom`. `lighteval eval` uses Inspect as the backend and is marked "(prefered)". Example: `lighteval eval "hf-inference-providers/openai/gpt-oss-20b" gpqa:diamond`. Custom tasks are written in Python: a `prompt_fn(line, task_name) -> Doc(query, choices, gold_index)`, a `LightevalTaskConfig(...)`, an optional `SampleLevelMetric(sample_level_fn, corpus_level_fn=np.mean)`, and a `TASKS_TABLE` list, loaded with `--custom-tasks path.py`.

**S8. promptfoo** (R8). *verified: yes.*
A CLI and library (Node, also `pip install promptfoo` and `npx`) for prompt, agent and RAG evals and red teaming. The README says it is "now part of OpenAI", remains MIT, and that "LLM evals run 100% locally". It is configured in `promptfooconfig.yaml` (`prompts`, `providers`, `tests[].vars`, `tests[].assert`). Assertion types (from `site/docs/configuration/expected-outputs`) include `equals`, `contains`, `icontains`, `contains-any`, `contains-all`, `starts-with`, `regex`, `is-json`, `contains-json`, `similar(threshold)`, `llm-rubric`, `factuality`, `javascript`, `python`, `levenshtein`, plus `not-` negation. Commands are `promptfoo eval` and `promptfoo view`, and it integrates with CI/CD.

**S9. DeepEval** (R9). *verified: yes.*
A pytest-style framework that runs with `deepeval test run test_x.py`. Its core types are `LLMTestCase(input, actual_output, expected_output, ...)` and metrics such as `GEval`, `AnswerRelevancyMetric`, faithfulness and `TaskCompletionMetric`, each with a `threshold`. It supports tracing (`@observe`, `update_current_span`) and `dataset.evals_iterator(metrics=[...])` for "trajectory-based evaluations". By default it uses OpenAI as the judge, and custom judge LLMs are supported.

**S10. RAGAS** (R10) and the paper (P9, arXiv 2309.15217, Es et al., Sept 2023). *verified: yes.*
The paper introduced reference-free RAG metrics (faithfulness, answer relevance, context relevance). The current library API (README) uses `ragas.metrics.DiscreteMetric(name, allowed_values, prompt)` with `await metric.ascore(llm=llm, response=...)` returning `.value` and `.reason`, and `llm_factory("gpt-4o", client=AsyncOpenAI())`. Note the repo move to `vibrantlabsai/ragas`.

**S11. Braintrust `Eval()` and `autoevals`** (R13). *verified: yes.*
In the `Eval("project", experiment_name=..., data=[{"input","expected"}], task=fn, scores=[ExactMatch])` pattern (docs.braintrust.dev/start/eval-sdk), you run `bt eval file.py` with `BRAINTRUST_API_KEY` set. `autoevals` is the open scorer library. LLM scorers like `Factuality()` are called as `evaluator(output, expected, input=...)` and return `.score` in [0,1] and `.metadata['rationale']`. It also has heuristic scorers and an async API (`eval_async`).

**S12. Langfuse** (R12). *verified: yes.*
An open-source and self-hostable LLM engineering platform covering tracing, prompt management, datasets, experiments, LLM-as-judge, annotation queues and user feedback. SDK experiment pattern (langfuse.com docs): `langfuse.run_experiment(name, data, task, evaluators)`, where `task(*, item, **kwargs)` and evaluators `(*, input, output, expected_output, metadata, **kwargs) -> Evaluation(name, value, comment)`. Anthropic's guide recommends it when self-hosting or data residency is needed.

**S13. LangSmith and `openevals`** (R24). *verified: partial.*
LangSmith docs (docs.langchain.com/langsmith/evaluate-llm-application) describe the pattern `client.create_dataset(...)`, a target `fn(inputs: dict) -> dict`, and evaluators `fn(inputs, outputs, reference_outputs) -> bool|score`, run with `evaluate(target, data=..., evaluators=[...], experiment_prefix=..., max_concurrency=4)`. I confirmed this through a summarising fetch, not the raw markdown, hence partial. `openevals` (MIT, R24) provides `create_llm_as_judge` and `create_trajectory_match_evaluator` (modes strict/unordered/subset/superset). Both were verified verbatim from the README.

**S14. Arize Phoenix and `phoenix-evals`** (R14). *verified: yes.*
An OSS observability platform covering tracing on OpenTelemetry/OpenInference, evaluation, datasets, experiments and a prompt playground. `phoenix.evals` API: `LLM(provider="openai", model=...)`, `create_classifier(name, prompt_template, llm, choices={...})`, `evaluator.evaluate({...}, input_mapping={...})`, plus built-ins `FaithfulnessEvaluator`, `exact_match` and `MatchesRegex`. The README lists skills such as `phoenix-error-analysis` (sample traces → failure categories), `phoenix-evals` and `phoenix-harbor`.

**S15. W&B Weave** (R15). *verified: yes.*
`weave.init(project)` sets up tracing. `@weave.op` traces functions, and `Evaluation(dataset=examples, scorers=[fn])` is run with `asyncio.run(evaluation.evaluate(model))`. Scorer rule from the docs (now hosted at docs.coreweave.com/weave): a scorer must take an `output` kwarg, and its other arguments must match dataset keys (the old `model_output` name is legacy). The README shows newer agent-tracing context managers (`start_conversation`, `start_turn`, `start_llm`) and notes that "Always pass `provider_name`".

**S16. OpenAI Agents SDK** (R11). *verified: yes (for what is claimed).*
The SDK has no dedicated eval module. Evals rest on **tracing**: `add_trace_processor()` adds a destination and `set_trace_processors()` replaces the defaults. The docs list integrations with W&B Weave, Braintrust, Langfuse and others. The repo's examples include plain Python outcome-checkers, e.g. `examples/sandbox/tutorials/repo_code_review/evals.py`, which validates `findings.jsonl` and `fix.patch` against expected files and keywords. Treat it as "evaluate the artifacts the agent produced plus the trace".

**S17. Prime Intellect `verifiers`** (R16). *verified: yes.*
"Our library for RL environments + evals", originally by Will Brown (2025 citation), and integrated with the Environments Hub and `prime-rl`. The current API is `verifiers.v1`. **TaskData** is an immutable row, a **Task** holds lifecycle hooks (`setup`, `finalize`, `validate`) plus `@vf.reward` and `@vf.metric` methods, and a **Taskset** has a `load()` that returns tasks. Concepts also include Harness (e.g. Claude Code, Codex, mini-swe-agent), Agent (harness × model × runtime policy), Environment (control flow across agents in an episode), Toolset (MCP), and Trace. Isolated grading sandboxes come from `ScoringConfig(mode="isolated")`. The CLIs are `vf-validate <taskset>` (checks gold solutions with no model call), `vf-debug` and `vf-run`, with full evals going through `uv run eval` in prime-rl.

**S18. rliable** (R17) and the paper (P3). *verified: yes.*
Agarwal et al., "Deep Reinforcement Learning at the Edge of the Statistical Precipice" (arXiv 2108.13264, NeurIPS 2021 Outstanding Paper per the repo description). It advocates interval estimates, performance profiles and IQM. Library API: `rly.get_interval_estimates(score_dict, aggregate_func, reps=50000)` with `metrics.aggregate_iqm/median/mean/optimality_gap` and `metrics.probability_of_improvement`, plus plotting. **The repo is archived (last push Aug 2024)**, so the book should present it as a reference implementation and reimplement it in numpy.

**S19. SWE-bench harness** (R18) and paper (P4, Jimenez, Yang et al., arXiv 2310.06770, Oct 2023; ICLR 2024 oral per README). *verified: yes.*
The current "v5" CLI: `swebench eval verified -p <predictions> --run-id <id> -j <workers>`, `swebench eval verified --gold` (sanity-check reference patches), `swebench report <run_id> -d verified` (re-grade logs without containers), `swebench infer verified -m gpt-5 -o preds` (uses mini-SWE-agent), `swebench images build`. The older `python -m swebench.harness.run_evaluation` still works. Pitfall stated in the README: **results are cached by `run_id` and `instance_id` only**, so a different patch under the same run_id is not re-evaluated. SWE-bench Verified is "a subset of 500 problems that real software engineers have confirmed are solvable" (README, Aug 2024). Cloud options are sb-cli and Modal.

**S20. tau-bench / tau2-bench** (R19, R20), papers P5 (Yao, Shinn et al., arXiv 2406.12045, June 2024) and P6 (Barres, Dong et al., arXiv 2506.07982, June 2025). *verified: yes.*
A simulation framework for customer-service agents in which a domain = policy + tools + tasks (+ optional user tools). τ² adds "dual-control" (the user can act too). The current repo is "τ-bench 2.0" with six languages, text and full-duplex voice, and the airline, retail and telecom domains (`text-v1`: 900 tasks = 6 languages × 3 domains × 50). CLI: `tau2 run --domain airline --agent-llm gpt-4.1 --user-llm gpt-4.1 --num-trials 1 --num-tasks 5`, `tau2 view`, `--dry-run`. pass^k comes from the original repo code (Section 2.4). Related: `amazon-agi/tau2-bench-verified` (59 stars), a corrected version.

**S21. BFCL** (R21), ICML 2025 paper (P12: Patil, Mao, Yan, Ji, Suresh, Stoica, Gonzalez; PMLR 267:48371-48392). *verified: partial (paper via proceedings listing; repo yes).*
Function-calling evaluation using AST checks, extended to multi-turn/multi-step (v3) and agentic web search, memory and format sensitivity (v4). CLI: `bfcl generate --model M --test-category simple_python,parallel,live_multiple,multi_turn`, then `bfcl evaluate --model M --test-category C [--partial-eval]`. Local models run with `--backend {sglang|vllm}`. Gorilla (arXiv 2305.15334) is the predecessor paper.

**S22. Harbor** (R22) and Terminal-Bench (R23, paper P13). *verified: yes.*
Harbor is "a framework from the creators of Terminal-Bench for evaluating and optimizing agents and language models". It evaluates arbitrary agents (Claude Code, OpenHands, Codex CLI), builds and shares benchmarks, runs thousands of containers in parallel (Daytona, Modal, etc.) and generates RL rollouts. Commands: `harbor run --dataset terminal-bench@2.0 --agent claude-code --model ... --n-concurrent 4 [--env daytona]` and `harbor datasets list`. Task format (from `skills/create-task/SKILL.md`): `instruction.md`, `task.toml`, `environment/Dockerfile`, `solution/solve.sh` (run by the Oracle agent) and `tests/test.sh`, which writes `/logs/verifier/reward.txt` or `reward.json`. Options include a separate verifier environment (`[verifier] environment_mode = "separate"`) and Reward Kit (`harbor-rewardkit`) for multi-criterion or judge grading. The paper is Merrill, Shaw, Carlini et al., "Terminal-Bench: Benchmarking Agents on Hard, Realistic Tasks in Command Line Interfaces" (arXiv 2601.11868, Jan 2026): 89 tasks, frontier agents below 65%.

**S23. HumanEval / Codex paper** (R25, P10: Chen, Tworek et al., arXiv 2107.03374, July 2021). *verified: yes.* This paper is the source of the unbiased pass@k estimator. The code is quoted in Section 2.3.

### 3c. Papers and articles

| # | Source | ID / URL | Contribution | Verified |
|---|---|---|---|---|
| P1 | Biderman et al., "Lessons from the Trenches on Reproducible Evaluation of Language Models" (2024-05-23) | arXiv 2405.14782 | Three years of lm-eval maintainer experience: sensitivity to setup, comparison difficulty, reproducibility. Codifies "folk knowledge" and recommends sharing code, prompts and per-sample outputs. | yes |
| P2 | Liang et al., "Holistic Evaluation of Language Models" (2022-11-16) | arXiv 2211.09110 | Multi-metric taxonomy (7 metrics × 16 core scenarios, 42 total, 30 models). | yes |
| P3 | Agarwal, Schwarzer et al., "Deep RL at the Edge of the Statistical Precipice" (2021-08-30) | arXiv 2108.13264 | IQM, stratified bootstrap CIs, performance profiles; basis of `rliable`. | yes |
| P4 | Jimenez, Yang et al., "SWE-bench" (2023-10-10) | arXiv 2310.06770 | Real GitHub issues verified by unit tests; the Docker harness. | yes |
| P5 | Yao, Shinn et al., "τ-bench" (2024-06-17) | arXiv 2406.12045 | Tool-agent-user simulation; introduces pass^k. | yes |
| P6 | Barres, Dong et al., "τ²-Bench" (2025-06-09) | arXiv 2506.07982 | Dual-control environment (user and agent both act); telecom domain. | yes |
| P7 | Miller, "Adding Error Bars to Evals" (2024-11-01) | arXiv 2411.00640 | Treats eval questions as draws from a super-population; formulas for SE, clustered SE, paired differences and power analysis. | yes |
| P8 | Zhu, Jin et al., "Establishing Best Practices for Building Rigorous Agentic Benchmarks" (2025-07-03) | arXiv 2507.02825 | Agentic Benchmark Checklist (ABC). Finds SWE-bench Verified has insufficient tests and TAU-bench "counts empty responses as successful", with mis-estimation up to 100% relative. Applying ABC to CVE-Bench cut overestimation by 33%. | yes |
| P9 | Es, James et al., "Ragas" (2023-09-26) | arXiv 2309.15217 | Reference-free RAG metrics. | yes |
| P10 | Chen, Tworek et al., "Evaluating LLMs Trained on Code" (2021-07-07) | arXiv 2107.03374 | HumanEval and the unbiased pass@k. | yes |
| P11 | Liu, Iter et al., "G-Eval" (2023-03-29) | arXiv 2303.16634 | CoT and form-filling LLM judge; the namesake of DeepEval's GEval. | yes |
| P12 | Patil et al., "The Berkeley Function Calling Leaderboard (BFCL)", ICML 2025 | proceedings.mlr.press/v267/patil25a.html | AST-based function-call evaluation and agentic extensions. | partial |
| P13 | Merrill, Shaw, Carlini et al., "Terminal-Bench" (2026-01) | arXiv 2601.11868 | 89 hard terminal tasks in Harbor format; frontier agents score below 65%. | yes |
| P14 | Gu, Tafjord et al., "OLMES: A Standard for Language Model Evaluations" (2024-06-12) | arXiv 2406.08446 | Documents prompt format, in-context example choice, normalisation and cloze vs. MC formulation as sources of irreproducibility. Implemented in `allenai/olmes`. | yes |
| P15 | Zheng, Chiang et al., "Judging LLM-as-a-Judge with MT-Bench and Chatbot Arena" (2023-06-09) | arXiv 2306.05685 | Judge biases (position, verbosity, self-enhancement); GPT-4 judges above 80% agreement with humans. | yes |
| P16 | Liu, Yu et al., "AgentBench" (2023-08-07) | arXiv 2308.03688 | Early multi-environment agent benchmark (OS, DB, KG, web). | yes |
| P17 | Yang, Lieret et al., "SWE-smith" (2025-04-30) | arXiv 2504.21798 | Scales SWE task creation for training; reuses the SWE-bench harness. | yes |
| P18 | Chan, Chowdhury et al., "MLE-bench" (2024-10-09) | arXiv 2410.07095 | Kaggle-style ML-engineering agent benchmark (repo R33). | yes |
| P19 | Miserendino, Wang et al., "SWE-Lancer" (2025-02-17) | arXiv 2502.12115 | Freelance SWE tasks with dollar value (repo archived). | yes |
| P20 | Hendrycks et al., "MMLU" (2020-09-07) | arXiv 2009.03300 | The canonical MC knowledge benchmark found in every harness. | yes |
| A1 | Grace, Hadfield, Olivares, De Jonghe, "Demystifying evals for AI agents", Anthropic Engineering (2026-01-09) | anthropic.com/engineering/demystifying-evals-for-ai-agents | Definitions (task, trial, grader, transcript, outcome, evaluation harness vs. agent harness, eval suite). Code, model and human graders; capability vs. regression evals; pass@k vs. pass^k. The appendix covers Harbor, Braintrust, LangSmith, Langfuse and Arize, and notes tools "are only as good as the eval tasks you run through them". | yes (fetched page summary) |
| A2 | Hamel Husain, "Your AI Product Needs Evals" (2024-03-29) | hamel.dev/blog/posts/evals/ | Three levels (unit-test assertions → human and model eval → A/B testing); start with binary labels; "Don't buy fancy LLM tools. Use what you have first"; measure judges with precision and recall. | yes |
| A3 | Braintrust Eval SDK quickstart | docs.braintrust.dev/start/eval-sdk | `Eval(data, task, scores)` pattern and the `bt eval` CLI. | yes |
| A4 | Langfuse "Experiments via SDK" | langfuse.com/docs/evaluation/experiments/experiments-via-sdk | `run_experiment` API. | yes |
| A5 | Weave Evaluations guide | docs.coreweave.com/weave/guides/core-types/evaluations | `Evaluation` and the scorer argument-matching rule. | yes |
| A6 | Inspect docs (index, custom scorers, metrics) | inspect.aisi.org.uk | Task/solver/scorer model, metrics, epochs and reducers. | yes |

**Verified source count:** 37 repositories with metadata checked (23 with READMEs or source opened and APIs confirmed), 20 papers (19 checked on arXiv, 1 through proceedings listings), and 6 articles or docs pages. About 55 sources were opened and confirmed, of which 3 are marked partial (BFCL paper, LangSmith docs, Anthropic article details from a summarising fetch).

Dropped or unverified: the "Long-Horizon Terminal-Bench" arXiv 2607.08964 (third-party mention only); the OpenAI "Introducing SWE-bench Verified" page (HTTP 403, so the facts are taken from the SWE-bench README instead).

---

## 4. Concrete code patterns from real repos

### 4.1 lm-eval: YAML task (from `lm_eval/tasks/gsm8k/gsm8k.yaml`)

```yaml
task: gsm8k
dataset_path: openai/gsm8k
dataset_name: main
output_type: generate_until
fewshot_split: train
test_split: test
doc_to_text: "Question: {{question}}\nAnswer:"
doc_to_target: "{{answer}}"
metric_list:
  - metric: exact_match
    aggregation: mean
    higher_is_better: true
    ignore_case: true
    regexes_to_ignore: [",", "\\$", "(?s).*#### ", "\\.$"]
generation_kwargs:
  until: ["Question:", "</s>", "<|im_end|>"]
  do_sample: false
  temperature: 0.0
num_fewshot: 5
filter_list:
  - name: "strict-match"
    filter:
      - function: "regex"
        regex_pattern: "#### (\\-?[0-9\\.\\,]+)"
      - function: "take_first"
```

Run: `lm_eval --model hf --model_args pretrained=EleutherAI/pythia-160m --tasks gsm8k --limit 10 --log_samples --output_path out/`, or use `--model local-completions --model_args model=...,base_url=http://host:8000/v1/completions` for an OpenAI-compatible server. Python API: `lm_eval.simple_evaluate(model="hf", model_args="pretrained=gpt2", tasks=["hellaswag"])`. For a custom model, subclass `lm_eval.api.model.LM` and implement `loglikelihood`, `generate_until` and `loglikelihood_rolling`.

Multiple-choice YAML idiom (from `docs/new_task_guide.md`):

```yaml
doc_to_text: "{{support.lstrip()}}\nQuestion: {{question}}\nAnswer:"
doc_to_target: 3
doc_to_choice: "{{[distractor1, distractor2, distractor3, correct_answer]}}"
```

### 4.2 Inspect: Q&A task, custom scorer, agent task

Hello world (docs index):

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
# inspect eval simpleqa.py --model openai/<model> ; inspect view
```

Custom scorer (docs "Custom Scorers"):

```python
@scorer(metrics=[accuracy(), stderr()])
def close_enough(rel_tol: float = 0.01):
    async def score(state: TaskState, target: Target) -> Score:
        numbers = re.findall(r"-?\d+(?:\.\d+)?", state.output.completion)
        if not numbers:
            return Score(value=INCORRECT, explanation="No number found in output.")
        answer = numbers[-1]
        expected = float(target.text)
        correct = abs(float(answer) - expected) <= rel_tol * abs(expected)
        return Score(value=CORRECT if correct else INCORRECT,
                     answer=answer, explanation=state.output.completion)
    return score
```

`CORRECT/INCORRECT/PARTIAL/NOANSWER` = `"C"/"I"/"P"/"N"`, which map to 1.0/0.0/0.5/0.0 through `value_to_float()`. Unknown strings such as `"pass"` become 0.0 unless you supply a converter. This trap is worth teaching.

Agent CTF task (docs index):

```python
@task
def ctf():
    return Task(
        dataset=json_dataset("challenges.json"),
        solver=react(prompt="You are a Capture the Flag player. ...",
                     tools=[bash(), todo_write()], attempts=3),
        scorer=includes(),
        sandbox="docker",
    )
```

Statistics: `metrics=[accuracy(), stderr(cluster="category")]`, `grouped(accuracy(), "category")`, `epochs=Epochs(5, ["mean", "pass_at_5"])`, CLI `--epochs 5 --epochs-reducer pass_k_3`. Offline model: `--model mockllm/model` (default output) or `get_model("mockllm/model", custom_outputs=[ModelOutput.from_content(...)])`. The constructor accepts an iterable, generator or callable, per `mockllm.py`. `ModelOutput.from_content` is listed in the Inspect API reference in `llms-full.txt`.

### 4.3 lighteval custom task (`docs/source/adding-a-custom-task.mdx`)

```python
def prompt_fn(line: dict, task_name: str):
    return Doc(task_name=task_name, query=line["question"],
               choices=[f" {c}" for c in line["choices"]], gold_index=line["gold"])

task = LightevalTaskConfig(name="myothertask", prompt_function=prompt_fn,
    hf_repo="your_dataset_repo_on_hf", hf_subset="default",
    hf_avail_splits=["train", "test"], evaluation_splits=["test"],
    few_shots_split="train", few_shots_select="random_sampling_from_train",
    metrics=[Metrics.ACCURACY], generation_size=256, stop_sequence=["\n", "Question:"])
TASKS_TABLE = [task]
# lighteval accelerate ... --custom-tasks path/to/file.py
```

### 4.4 promptfoo (`examples/getting-started/promptfooconfig.yaml`)

```yaml
prompts:
  - 'Convert the following English text to {{language}}: {{input}}'
providers:
  - openai:<model-a>
  - openai:<model-b>
tests:
  - vars: { language: French, input: Hello world }
    assert:
      - type: contains
        value: 'Bonjour le monde'
  - vars: { language: Spanish, input: Where is the library? }
    assert:
      - type: icontains
        value: 'Dónde está la biblioteca'
```

Other assertion examples include `llm-rubric: does not describe self as an AI...`, `javascript: output.length < 100`, `python: len(output) > 10` and `not-contains:error`.

### 4.5 DeepEval (README)

```python
from deepeval import assert_test
from deepeval.metrics import GEval
from deepeval.test_case import LLMTestCase, SingleTurnParams

def test_case():
    correctness_metric = GEval(
        name="Correctness",
        criteria="Determine if the 'actual output' is correct based on the 'expected output'.",
        evaluation_params=[SingleTurnParams.ACTUAL_OUTPUT, SingleTurnParams.EXPECTED_OUTPUT],
        threshold=0.5)
    test_case = LLMTestCase(input="What if these shoes don't fit?",
        actual_output="You have 30 days to get a full refund at no extra cost.",
        expected_output="We offer a 30-day full refund at no extra costs.")
    assert_test(test_case, [correctness_metric])
# deepeval test run test_ai_agent.py
```

### 4.6 Braintrust / Langfuse / Weave / Phoenix: one shape, four spellings

| Tool | Data | Target | Scorer signature | Run |
|---|---|---|---|---|
| Braintrust | `[{"input","expected"}]` | `task(input)` | autoevals `Scorer(output, expected, input=)` → `.score` | `Eval(...)`; `bt eval f.py` |
| Langfuse | `[{"input","expected_output"}]` or dataset | `task(*, item, **kw)` | `(*, input, output, expected_output, metadata, **kw) -> Evaluation(name,value,comment)` | `langfuse.run_experiment(...)` |
| Weave | list of dicts | `Model.predict(self, question)` | `@weave.op def s(expected, output)`; the arg names match columns, and `output` is required | `asyncio.run(Evaluation(...).evaluate(model))` |
| LangSmith | dataset of `inputs`/`outputs` | `fn(inputs: dict) -> dict` | `fn(inputs, outputs, reference_outputs) -> bool` | `evaluate(..., experiment_prefix=, max_concurrency=)` |
| Phoenix | dict rows | n/a | `create_classifier(...).evaluate(row, input_mapping=)` | experiments in the UI/SDK |

**Teaching idea:** write a 40-line stdlib `run_experiment(data, task, scorers)` that shows these are all the same loop: dataset → target → scorers → aggregate → log.

### 4.7 verifiers v1 (docs/tasksets.md, docs/building-environments.md)

```python
import verifiers.v1 as vf

class AdditionData(vf.TaskData):
    answer: int

class AdditionTask(vf.Task[AdditionData]):
    @vf.reward
    async def exact_match(self, trace: vf.Trace) -> float:
        return float(trace.last_reply == str(self.data.answer))

class AdditionConfig(vf.TasksetConfig):
    num_tasks: int = 100

class AdditionTaskset(vf.Taskset[AdditionTask, AdditionConfig]):
    def load(self) -> list[AdditionTask]:
        return [AdditionTask(AdditionData(prompt=f"What is {i} + {i}?", answer=2 * i),
                             self.config.task)
                for i in range(self.config.num_tasks)]
```

Container plus isolated grading (`FileSumTask`): `setup()` writes `/app/input.txt` and an empty `/app/output/answer.txt`, so that an untouched task scores 0 instead of erroring. `@vf.reward correct()` reads the answer file. `validate()` writes the gold answer and asserts reward == 1. `TaskData(..., image="python:3.11-slim", scoring=vf.ScoringConfig(mode="isolated"), artifacts=[vf.Artifact(source="/app/output")])`. Sanity check: `uv run vf-validate reverse-text -n 1`.

### 4.8 Harbor task (skills/create-task/SKILL.md)

```
my-task/
├── instruction.md          # prompt; "Don't leak the tests"
├── task.toml               # [task] name/version/keywords; [agent] timeout_sec; [verifier] timeout_sec; [environment] cpus/memory_mb/network_mode
├── environment/Dockerfile  # install what the task requires, NOT the solution
├── solution/solve.sh       # Oracle agent runs it to prove solvability
└── tests/test.sh           # writes /logs/verifier/reward.txt (0/1) or reward.json
```

```bash
#!/bin/bash
if diff -q /app/output.txt /tests/expected.txt; then
  echo 1 > /logs/verifier/reward.txt
else
  echo 0 > /logs/verifier/reward.txt
fi
```

Commands: `harbor task init "<org>/<name>"`, `harbor task start-env -p <path> -e docker -a -i`, `harbor run -d "<dataset@version>" -m "<model>" -a "<agent>"`.

### 4.9 SWE-bench predictions and evaluation

Predictions are JSONL with `instance_id`, `model_name_or_path` and `model_patch` (a unified diff). These are the standard field names. The README confirms `instance_id`, while `model_patch` and `model_name_or_path` come from the long-standing harness docs, so mark them partial. `swebench eval verified -p preds.jsonl --run-id r1 -j 8` writes `logs/evaluation/<run_id>/results.json`. Always run `--gold` first to validate the environment.

### 4.10 Ideas for runnable, self-contained teaching examples (stdlib/numpy, no API keys)

1. **`mini_harness.py`**: a ~150-line Inspect-like core with `Sample`, `Task(dataset, solver, scorer)`, an async runner with concurrency, a JSONL log and `accuracy`/`stderr`. The solver is a `MockModel` that answers deterministically from a lookup table with injected noise (`random.Random(seed)`).
2. **Filter ablation**: reproduce gsm8k strict-match vs. flexible-extract on 20 synthetic generations. Show how a 30-point gap comes purely from formatting.
3. **pass@k vs. pass^k calculator**: simulate tasks with heterogeneous per-task success probabilities `p_t ~ Beta(2,2)`, n=10 trials. Compare the unbiased estimators to the naive `1-(1-p̂)^k` and `p̂^k`, which are biased when estimated from few trials, and plot over k.
4. **Statistics pack**: Wilson vs. Wald CI, clustered SE, paired-difference test and a bootstrap. It reproduces the worked numbers in Section 2.5 exactly (0.715–0.917; 0.151 vs. 0.236; 0.133 vs. 0.226).
5. **rliable in numpy**: IQM plus a stratified bootstrap over a (runs × tasks) matrix, and a performance profile, from about 40 lines that replace the archived library.
6. **Mock LLM judge with bias**: a judge that prefers longer answers and position A with probability 0.6. Show how swapping order and averaging removes position bias. Compute judge precision and recall against synthetic "human" labels (Hamel's advice).
7. **Toy tool-calling checker (BFCL-style)**: parse a model's call string with Python `ast`, then check the function name, required args and allowed values. Add a trajectory matcher with strict/unordered/subset/superset modes (an openevals clone).
8. **Toy tau-style environment**: a dict "database" of orders, tools `get_order` and `cancel_order`, and a policy that forbids cancelling shipped orders. A scripted user and a mock agent run 5 trials. Score by **final DB state equality**, then compute pass^k.
9. **Harbor-format task runner without Docker**: build a temp dir with instruction.md/tests/test.sh, run `solve.sh` (the Oracle) via `subprocess`, read `reward.txt`, and show that a "null agent" scores 0. That is the verifier sanity check.
10. **Reward-hacking demo**: a verifier that only checks that an output file *exists* is beaten by an agent that writes an empty file. Fix it with content checks and an isolated grading dir (verifiers' `mode="isolated"` idea; ABC checklist).
11. **SWE-bench cache trap**: a mini harness that caches by `(run_id, instance_id)`. Re-submit a different patch and watch it get the stale result.
12. **Promptfoo-like YAML runner**: parse a tiny YAML/JSON test file of `vars` and `assert` (`contains`, `icontains`, `regex`, `is-json`, `python`) against a mock provider and print a matrix.

---

## 5. Pitfalls, debates, open problems and practitioner advice

**Pitfalls**

- **Same benchmark name, different number.** Prompt format, few-shot count, CoT vs. none, logprob vs. generative scoring, length normalisation and answer extraction all change scores (OLMES; lm-eval "Lessons from the Trenches"; simple-evals' zero-shot CoT stance). Always report the harness, version, task version (`metadata.version` in YAML), prompt and filter.
- **Answer extraction is part of the metric.** strict vs. flexible gsm8k. Inspect's `answer()` and `pattern()` flag `reason="invalid_response_format"`. Look at `--log_samples` and `--limit 10` first (lm-eval README advice).
- **Silent score coercion.** Inspect maps unknown string values to 0.0, and DeepEval and Phoenix thresholds turn continuous judge scores into pass/fail. Know your converter.
- **Caching and stale results.** SWE-bench caches by `(run_id, instance_id)`, and promptfoo and others cache provider calls. Change the run IDs and disable caches for final runs.
- **Broken tasks and lenient graders.** ABC (arXiv 2507.02825) found insufficient SWE-bench Verified tests and TAU-bench counting empty responses as success, with mis-estimation up to 100% relative. Terminal-Bench 2.1 modified 26 tasks for bugs, timeouts and reward-hacking robustness (repo description via search result; partial). Mitigations: an Oracle/gold run (`swebench --gold`, Harbor `solve.sh`, `vf-validate`), a null-agent run, and isolated verifiers.
- **Grader leakage and reward hacking.** Agents can read `/tests`. Harbor's "separate verifier environment", verifiers' isolated scoring and "Don't leak the tests" in instructions all address this.
- **Non-independence.** Clustered questions (shared passages, same repo) need clustered SEs. Small agent suites (e.g. 50 tasks per domain in tau2) produce wide intervals, so report CIs and run multiple trials.
- **Agent = model × scaffold.** Harbor and verifiers make the harness explicit (`--agent claude-code`, harness id `bash`). Comparing models across different scaffolds confounds the result.
- **Infrastructure noise.** Container resource limits, timeouts, network policy (Harbor `network_mode`, cpus, memory_mb) and API flakiness change agent scores. Record them in the task config.
- **Archived or deprecated tools.** rliable (archived), simple-evals (deprecated), langsmith-sdk repo (archived/moved), METR vivaria (archived), OpenAI evals (no custom-code evals). The book should state "as of Nov 2026".
- **Judge models drift.** Hosted judges (`model_graded_qa`, GEval, `llm-rubric`) change over time. Pin judge versions and calibrate against human labels (precision and recall, not raw agreement; Hamel).

**Debates**

- **Standard harness vs. bespoke evals.** Leaderboard reproducibility (lm-eval, HELM, OLMES) vs. product relevance (Hamel's "Use what you have first"; the Anthropic guide's warning that tools "are only as good as the eval tasks you run through them").
- **Few-shot vs. zero-shot CoT** for chat models (simple-evals vs. classic harness defaults).
- **pass@k vs. pass^k.** pass@k suits capability or best-of-n settings, and pass^k suits reliability for customer-facing agents (tau-bench; Anthropic guide).
- **LLM-as-judge validity**: scalable and above 80% agreement (MT-Bench), but biased. G-Eval-style probability weighting, multi-judge consensus and human calibration.
- **Open-source vs. SaaS observability**: self-hosted Langfuse and Phoenix for data residency vs. managed Braintrust and LangSmith.

**Open problems**

- Standard, portable task formats across harnesses (Harbor tasks, verifiers tasksets, Inspect tasks; adapters are multiplying).
- Verifying open-ended agent outcomes (research, browsing) without brittle tests or costly judges.
- Cost-aware reporting (tokens, wall-clock, dollars) alongside accuracy. HELM's efficiency metric is an early example.
- Contamination of public benchmarks, and the move to private or held-out sets (inspect_evals' policy changes, Verified subsets).
- Voice and multimodal agent evals (tau-bench 2.0 full-duplex voice; lmms-eval).

**Practitioner recommendations (synthesised from sources)**

1. Start with 20–50 real failure cases from traces, labelled binary pass/fail (Hamel; Phoenix error-analysis skill).
2. Prefer code-based graders on *outcomes*, add model graders for nuance, and calibrate them with humans (Anthropic guide).
3. Validate every task with a gold or Oracle solution and a null agent before trusting scores (SWE-bench `--gold`, Harbor Oracle, `vf-validate`).
4. Run multiple trials. Report mean ± SE or a Wilson CI, plus pass@k and pass^k as relevant, and use paired comparisons between models (Miller; Inspect metrics).
5. Pin everything: harness version, task version, dataset revision, container image, judge model, sampling params.
6. Keep capability evals and regression evals separate, and run regressions in CI (promptfoo, DeepEval, `bt eval`).
7. Log full transcripts and read them (Inspect `inspect view`, Harbor and Phoenix traces).

---

## 6. Suggested sub-sections for the book chapter ("Chapter 9: The Eval Tooling Landscape")

1. **Map of the territory.** The six layers (Section 1 table) and the shared vocabulary of task, trial, solver, scorer, transcript and aggregate.
2. **Anatomy of a harness.** Build `mini_harness.py` from scratch with a mock model, concurrency, logs and metrics. This is the "aha" that every tool is this loop.
3. **Benchmark harnesses.** lm-eval (YAML tasks, filters, the dummy model, `simple_evaluate`), lighteval (custom task, Inspect backend), HELM (multi-metric runs), simple-evals (zero-shot CoT philosophy), OLMES (standardisation). Exercise: the strict vs. flexible gsm8k gap.
4. **Inspect in depth.** Datasets, solvers, scorers, custom scorer, epochs and reducers, clustered stderr, sandboxes and `react()`, `mockllm` for testing, logs and `inspect view`, inspect_evals.
5. **Agent and environment harnesses.** SWE-bench (predictions, `--gold`, cache trap), tau2-bench (domains, user simulator, pass^k), BFCL (AST checking, multi-turn), Harbor (task directory, reward.txt, Oracle, separate verifier, Terminal-Bench 2.x).
6. **Evals as RL environments.** verifiers v1 (TaskData/Task/Taskset, `@vf.reward`, isolated grading, `vf-validate`), Harbor rollouts, and how a verifier becomes a reward.
7. **App-level testing libraries.** promptfoo YAML assertions, DeepEval pytest and GEval, RAGAS, autoevals, openevals (judge and trajectory match), phoenix-evals. A comparison table.
8. **Observability-driven evals.** Datasets, experiments and online evals in LangSmith, Langfuse, Braintrust, Phoenix and Weave. The one-shape-four-spellings table. Hooking the OpenAI Agents SDK into them with trace processors.
9. **Statistics in the tools.** pass@k and pass^k estimators (code from human-eval and tau-bench), Wilson CI, clustered and paired SE, IQM and bootstrap (rliable reimplemented), with worked numbers.
10. **Choosing a stack.** A decision guide by use case: pre-training checkpoint sweeps → lm-eval or lighteval; frontier capability or safety evals → Inspect; coding or terminal agents → SWE-bench or Harbor; customer-service agents → tau2; RL training → verifiers or Harbor; product regression in CI → promptfoo or DeepEval; production monitoring → Langfuse, Phoenix, Braintrust, LangSmith or Weave.
11. **Pitfalls and a checklist.** Reproducibility, caching, extraction, task validity (ABC), grader isolation, scaffold confounds, infrastructure noise, judge drift, deprecated tools.
12. **Hands-on labs.** The 12 teaching examples from Section 4.10, all runnable offline.
