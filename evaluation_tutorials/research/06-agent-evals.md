# Research Dossier 06: Evaluating AI Agents (tool use, trajectories, coding/web/computer-use agents)

Prepared 2026-11-20 as the factual basis for the agent-evaluation chapter of *Evaluations for AI: LLMs, Agents and RL Environments*.

**How it was verified.** I opened every arXiv paper below on its abstract page (`arxiv.org/abs/<id>`) and checked the title, first authors and submission date against the `citation_*` meta tags. I quote numbers from the abstract or the arXiv HTML full text. I read the code snippets from the repos' `main`/`master` branches through `raw.githubusercontent.com` on 2026-11-20. Star counts and last-push dates come from the GitHub search API on the same day. `verified: yes` means I read the primary source and found the claim in it. `verified: partial` means the source exists but I could only check the claim through search snippets or secondary sources, so the chapter should word it carefully.

---

## 1. Overview: what agent evaluation is and how the parts fit together

An **agent** here means an LLM in a loop. It receives an observation, chooses an action (a tool call, a shell command, a GUI click, a message to a user), the environment changes, and the loop repeats until the agent stops or hits a budget. Evaluating an agent differs from evaluating a single LLM completion in five ways:

1. **The unit of evaluation is a trajectory (transcript, trace), not a completion.** Anthropic's guide defines a *trial* as one attempt at a task. The *transcript* is "the complete record of a trial, including outputs, tool calls, reasoning, intermediate results". The *outcome* is "the final state in the environment at the end of the trial" (Anthropic, *Demystifying evals for AI agents*, 2026).
2. **What you evaluate is the model plus its harness.** "When we evaluate 'an agent,' we're evaluating the harness and the model working together" (same source). SWE-agent's main claim is that the *agent-computer interface* changes results a lot (arXiv:2405.15793). HAL (arXiv:2510.11977) therefore treats models, scaffolds and benchmarks as three separate axes.
3. **The environment is part of the measuring instrument.** Docker images, live websites, VMs, databases and simulated users can all be flaky, leak answers or drift over time. These faults bias results in both directions. OSWorld's Chrome tasks were underestimated by 28% after website changes broke the HTML selectors (ABC, arXiv:2507.02825).
4. **Results are stochastic and multi-dimensional.** You need repeated trials, reliability metrics (pass^k), cost, latency and token counts as well as success.
5. **Agents act, so they can cheat or cause harm.** Examples include reward hacking (METR 2025), collateral damage (AppWorld's state-based tests check for "unexpected changes"), and safety violations such as "misusing credit cards in flight booking tasks" (HAL).

### Taxonomy map (how the pieces relate)

```
                    ┌──────────── WHAT is graded ────────────┐
                    │ Outcome (end state / final answer)      │
                    │ Trajectory (process: steps, tool calls) │
                    │ Efficiency (cost, tokens, latency, turns)│
                    │ Reliability (pass^k, variance)          │
                    │ Safety/side-effects (collateral damage) │
                    └─────────────────────────────────────────┘
                                   ▲
 HOW it is graded: code-based (unit tests, state/DB hash, AST match,
   string match) | model-based (LLM rubric, Agent-as-a-Judge) | human
                                   ▲
 WHERE (environment): repo+tests (SWE-bench), terminal container
   (Terminal-Bench), simulated APIs+DB+user (tau-bench), self-hosted
   websites (WebArena), VMs (OSWorld), live web (GAIA, BrowseComp),
   Kaggle (MLE-bench), papers (PaperBench), CTF boxes (Cybench)
                                   ▲
 HARNESS: task spec -> sandbox setup -> agent loop -> logging/tracing
   -> graders -> aggregation (CI, pass^k, cost) -> transcript review
```

### Benchmark families (cheat sheet)

| Family | Representative benchmarks | Grading mechanism |
|---|---|---|
| Software engineering | SWE-bench (Full/Lite/Verified/Multimodal/Multilingual), SWE-bench Pro, SWE-Lancer, SWE-rebench | Hidden unit tests: FAIL_TO_PASS + PASS_TO_PASS; E2E tests (SWE-Lancer) |
| Terminal / ops | Terminal-Bench 2.0, InterCode | Per-task test scripts in a container |
| Tool / function calling | BFCL (v1-v4), ToolBench/ToolLLM, ToolSandbox, AppWorld | AST match, executable checks, state-based unit tests, milestones |
| Conversational tool-agent-user | tau-bench, tau2-bench | Final DB state vs. annotated goal state, plus required outputs; pass^k |
| Web | WebShop, Mind2Web, WebArena, VisualWebArena, WorkArena, BrowseComp | Functional correctness (URL/DB/page checks), answer match |
| Computer use / OS | OSWorld, Windows Agent Arena, AndroidWorld | Per-task execution-based evaluation scripts on VM state |
| General assistants | GAIA, AgentBench, TheAgentCompany | Exact answer match; checkpoints with partial credit |
| Autonomy / R&D / time horizon | METR HCAST, RE-Bench, time-horizon metric, MLE-bench, PaperBench | Scored tasks with human baselines; Kaggle medals; rubric trees graded by an LLM judge |
| Security | Cybench | CTF flag capture, plus subtask guidance |
| Meta-evaluation | ABC checklist, HAL, "AI Agents That Matter", SWE-bench+, SWE-Bench Illusion | Audits of benchmarks themselves |

---

## 2. Key concepts, definitions, formulas, worked examples

### 2.1 Task, trial, grader, transcript, outcome, harness
These are the definitions from Anthropic (Jan 9, 2026). A **task** is a single test with inputs and success criteria. A **trial** is one attempt. A **grader** is the logic that scores some aspect of performance, and one task can have several. The **transcript** is the full trace. The **outcome** is the final environment state. An **evaluation harness** "provides instructions and tools, runs tasks concurrently, records all the steps, grades outputs, and aggregates results". The **agent harness / scaffold** is the system that turns the model into an agent. An **eval suite** is a collection of tasks.

The flight-booking example makes the outcome-versus-transcript distinction concrete. The agent may *say* "Your flight has been booked", but the outcome is whether a reservation row exists in the database.

### 2.2 Outcome vs. trajectory evaluation
- **Outcome (end-state) evaluation** checks the final world state. tau-bench "compares the database state at the end of a conversation with the annotated goal state". OSWorld runs "a custom execution-based evaluation script" per task. WebArena evaluates "functional correctness". AppWorld uses "state-based unit tests, allowing for different ways of completing a task while also checking for unexpected changes, i.e., collateral damage".
  - Pros: agents can reach the goal by any valid path, and the check is hard to game when it is designed well.
  - Cons: it gives no partial signal and does not explain *why* an agent failed. It can also miss bad process, such as a correct result reached unsafely or by luck.
- **Trajectory (process) evaluation** grades the path. Examples are required tool calls, tool-call order, number of turns, policy compliance and milestones.
  - ToolSandbox uses "a dynamic evaluation strategy for intermediate and final milestones over an arbitrary trajectory".
  - AgentBoard proposes a "fine-grained progress rate metric that captures incremental advancements".
  - Cybench adds subtasks "for a more detailed evaluation".
  - Agent-as-a-Judge uses an agent to give "intermediate feedback for the entire task-solving process".
  - OpenAI's trace grading assigns "structured scores or labels to an agent's trace".
- **Practitioner consensus.** Anthropic: "There is a common instinct to check that agents followed very specific steps like a sequence of tool calls in the right order. We've found this approach too rigid and results in overly brittle tests… it's often better to grade what the agent produced, not the path it took." Use trajectory checks for things you actually require, such as safety, policy, efficiency and a mandatory confirmation step. Do not use them to enforce one canonical path.

### 2.3 pass@k (unbiased estimator, Chen et al. 2021)
Draw n ≥ k samples per task, count the c correct ones, and compute

  pass@k = E_tasks [ 1 − C(n−c, k) / C(n, k) ]

The HumanEval repo implements this in a numerically stable product form (§4.1). pass@k is the probability that **at least one** of k i.i.d. attempts succeeds. It suits settings where a verifier can choose the successful attempt, or where only one success is needed.

### 2.4 pass^k ("pass-hat-k", Yao et al. 2024, tau-bench)
pass^k is the probability that **all k** i.i.d. attempts succeed. The unbiased estimator per task is C(c, k)/C(n, k), averaged over tasks (code in §4.2). At k=1 it equals pass@1 and the average success rate. As k grows, pass@k rises and pass^k falls. tau-bench reports that "even state-of-the-art function calling agents (like gpt-4o) succeed on <50% of the tasks, and are quite inconsistent (pass^8 <25% in retail)".

Anthropic's worked example: a per-trial success rate of 75% and 3 trials give (0.75)^3 ≈ 42% pass^3. They also note: "By k=10, they tell opposite stories: pass@k approaches 100% while pass^k falls to 0%."

**Worked example (I ran it with Python stdlib).** Take n = 8 trials per task and 4 tasks with success counts c = {8, 6, 2, 0}.

| k | pass@k | pass^k |
|---|---|---|
| 1 | 0.500 | 0.500 |
| 2 | 0.607 | 0.393 |
| 4 | 0.696 | 0.304 |
| 8 | 0.750 | 0.250 |

The per-task pass^2 values are: task B = C(6,2)/C(8,2) = 15/28 = 0.536, task C = 1/28 = 0.036, task A = 1, task D = 0, giving a mean of 0.393. Note that pass@8 equals the fraction of tasks solved at least once (3/4), and pass^8 equals the fraction of tasks solved every time (1/4).

### 2.5 Statistical uncertainty for agent benchmarks
The chapter should cross-reference the statistics chapter. With N tasks and a binary score, the standard error is SE = √(p(1−p)/N). For SWE-bench Verified (N = 500) at p = 0.6, SE ≈ 0.0219, so the 95% CI is about ±4.3 percentage points. Many leaderboard gaps are therefore within noise. Practical recommendations:
- Use **paired comparisons** on the same tasks (McNemar's test, or a paired bootstrap over tasks).
- **Cluster** by task family or repo. METR weights each task in a family of size n by 1/√n and uses a hierarchical bootstrap.
- Separate **within-task variance**, which repeated trials reduce, from **between-task variance**, which only more tasks reduce.

### 2.6 Resolution rate (SWE-bench family)
An instance counts as **resolved** only if every FAIL_TO_PASS test passes (the tests that fail before the gold patch and pass after it) and every PASS_TO_PASS test still passes (regression protection). The harness also defines PARTIAL as 0 < F2P < 1 with P2P = 1, but the leaderboard metric is FULL (§4.3). The weakness is that the result is only as good as the tests. SWE-bench+ found that 31.08% of passed patches were "suspicious patches due to weak test cases". ABC notes that "24% of the top 50 leaderboard positions are incorrect" because of insufficient tests (citing prior work).

### 2.7 State-based grading (tau-bench, AppWorld, OSWorld)
The grader replays the ground-truth action sequence on a fresh copy of the database, hashes the result, and compares it to the hash of the agent's final database. Any difference in the write set fails the run. tau-bench also requires certain strings to appear in the agent's replies (`task.outputs`). This works whenever the task's effect is a deterministic state change.

One pitfall: if the goal state equals the initial state (for example, an impossible request that must be refused), an agent that does nothing passes. ABC found that "a trivial agent that returns empty responses is considered successful on intentionally impossible tasks… This trivial agent achieves a 38% success rate and outperforms a GPT-4o-based agent". Intentionally unsolvable tasks make up "38% of the airline subset and 6% of the retail subset".

### 2.8 AST-based tool-call correctness (BFCL)
BFCL parses the model's function call and checks it structurally against the schema and a set of acceptable answers. It checks that the function name matches, that required parameters are present, that there are no unexpected parameters, that types are correct, and that each value is in the allowed list. Strings are normalised: spaces and `,./-_*^` are removed and case is ignored. BFCL also has executable categories, multi-turn stateful categories (V3) and agentic categories (V4: web search, memory, format sensitivity). Overall accuracy is "the unweighted average of all the sub-categories" (leaderboard page). SQL is excluded from AST evaluation "due to the multiplicity of methods to construct SQL function calls achieving identical outcomes", which shows the limit of syntactic matching.

### 2.9 Multi-turn user simulators
- tau-bench simulates the user with an LM. tau2-bench adds a **dual-control** setting, "modeled as a Dec-POMDP, where both agent and user make use of tools to act in a shared, dynamic environment". Its user simulator is "tightly coupled with the environment, whose behavior is constrained by tools and observable states, improving simulation fidelity". It reports "significant performance drops when agents shift from no-user to dual-control".
- ToolSandbox has "a built-in user simulator supporting on-policy conversational evaluation". It contrasts this with off-policy evaluation over fixed dialog trajectories.
- MINT evaluates multi-turn interaction with tools and *language feedback*, where feedback is simulated by GPT-4.
- Design concerns: the simulator's own errors become label noise. The simulator can leak the goal or give up. Simulator variance adds to agent variance, so you should fix the simulator model and version and report them.

### 2.10 Time horizon (METR, arXiv:2503.14499)
The **50%-task-completion time horizon** is "the time humans typically take to complete tasks that AI models can complete with 50% success rate". METR fits a per-model logistic regression

  p_success(model, task) = σ((log h_model − log t_task) · β_model)

where t_task is the geometric mean time of successful human baselines. h_model is the time at which predicted success is 50%. Results reported:
- Claude 3.7 Sonnet had a horizon of about 50 minutes.
- o1 had about 39 minutes.
- Frontier horizons have been "doubling approximately every seven months since 2019, though the trend may have accelerated in 2024".
- The task suite has 170 tasks drawn from HCAST, RE-Bench and 66 short SWAA tasks.

The method is explicitly inspired by IRT, but it uses human time as the difficulty measure. The teaching example in §4.7 recovers h50 from synthetic data: true h = 30 min, fitted 23.5 min with 80 trials, which shows how wide the uncertainty is.

### 2.11 Cost-aware evaluation and Pareto frontiers (Kapoor et al., arXiv:2407.01502)
The paper argues that "AI agent evaluations must be cost-controlled", that results should be shown as accuracy-versus-cost Pareto curves, and that cost and accuracy should be optimised jointly. On HumanEval, simple baselines (retry, warming, escalation) matched the "state-of-the-art" agent architectures: "There is no significant accuracy difference between our warming strategy and the best-performing agent architecture". The paper also separates the needs of **model developers** from those of **downstream developers**, discusses shortcuts and inadequate holdouts (with a case study of the STeP agent on WebArena), and covers reproducibility. HAL builds this into a cost-aware leaderboard and reports that "higher reasoning effort reducing accuracy in the majority of runs".

Metrics to report:
- $ per task and $ per *successful* task
- input and output tokens
- wall-clock time and time-to-first-token
- number of turns and tool calls

Anthropic's example YAML tracks `n_turns`, `n_toolcalls`, `n_total_tokens`, `time_to_first_token`, `output_tokens_per_sec` and `time_to_last_token`.

### 2.12 Capability vs. regression evals; saturation
Anthropic distinguishes two kinds of eval.
- **Capability evals** "should start at a low pass rate".
- **Regression evals** "should have a nearly 100% pass rate". Capability tasks "graduate" into the regression suite once they are solved.

**Saturation** happens when an agent passes all solvable tasks. Anthropic says SWE-bench Verified went from about 40% to over 80% in one year. OpenAI stopped reporting SWE-bench Verified in 2026 and now recommends SWE-bench Pro (partially verified, §3). Anthropic also warns: "a 0% pass rate across many trials (i.e. 0% pass@100) is most often a signal of a broken task, not an incapable agent."

### 2.13 Grader taxonomy and combination
- **Code-based graders:** unit tests, state checks, static analysis, regex/AST matching, transcript statistics.
- **Model-based graders:** LLM rubrics and pairwise comparison. These need "calibration with human graders", benefit from an "Unknown" escape hatch, and work best with one isolated judge per rubric dimension.
- **Human graders:** used for calibration and subjective quality.

Scores can be combined as *weighted* (combined score must pass a threshold), *binary* (all graders must pass) or *hybrid*. Build in **partial credit** for multi-component tasks. TheAgentCompany and PaperBench use hierarchical rubric checkpoints; PaperBench has "8,316 individually gradable tasks".

---

## 3. Annotated source list (validated)

### A. Coding and software engineering agents
1. **SWE-bench: Can Language Models Resolve Real-World GitHub Issues?** Jimenez, Yang, Wettig et al. arXiv:2310.06770 (Oct 2023; ICLR 2024).
   - The canonical repository-level coding-agent benchmark. Tasks are real GitHub issues paired with PRs from 12 Python repos (2,294 instances), graded by running repo tests (FAIL_TO_PASS / PASS_TO_PASS).
   - Repo: github.com/SWE-bench/SWE-bench, 6.2k stars, pushed 2026-09-18. The site lists the Verified, Multilingual, Multimodal, Lite, Full and "Bash Only" leaderboards, along with mini-SWE-agent and SWE-smith.
   - **verified: yes.**
2. **SWE-bench Verified** (OpenAI blog "Introducing SWE-bench Verified", Aug 13, 2024).
   - A 500-instance subset screened by 93 professional Python developers, who annotated 1,699 samples for underspecification, invalid tests and difficulty. It is the most-cited agent coding number of 2024-25.
   - openai.com returned 403 to my fetch. The 500 / 93 / 1,699 figures come from search snippets of the OpenAI page and from the HAL leaderboard listing.
   - **verified: partial.**
3. **"Why we no longer evaluate SWE-bench Verified"** (OpenAI, Feb 2026).
   - OpenAI states the benchmark is "saturated due to test-design issues and contamination from public repositories", stops reporting it, and recommends SWE-bench Pro. Secondary sources cite an audit of 138 consistently failed problems with flawed tests (about 59.4% figure). Treat those numbers as unconfirmed.
   - **verified: partial** (page blocked; claims come from search snippets and the OpenAI Devs post).
4. **SWE-bench Multimodal.** Yang, Jimenez, Zhang et al. arXiv:2410.03859 (Oct 2024).
   - 617 tasks from 17 JavaScript libraries for visual, user-facing software, each with at least one image. SWE-agent resolves 12% against 6% for the next-best system. Useful for showing cross-language generalisation gaps.
   - **verified: yes.**
5. **SWE-Bench Pro: Can AI Agents Solve Long-Horizon Software Engineering Tasks?** Deng, Da, Pan et al. (Scale AI). arXiv:2509.16941 (Sep 2025).
   - 1,865 problems from 41 repos, split into a public set (11 repos), a held-out set (12) and a commercial set (18 proprietary startup repos). Tasks can take "hours to days" for a professional and are designed to be contamination-resistant.
   - Headline pass@1 differs between versions (v1 abstract under 45%; the Scale page reports GPT-5 at 23.3% on public). Cite the version you use.
   - Repo: scaleapi/SWE-bench_Pro-os, 569 stars, pushed 2026-09-22.
   - **verified: yes** (abstract), partial for the exact scores.
6. **SWE-Bench+: Enhanced Coding Benchmark for LLMs.** Aleithan et al. arXiv:2410.06992 (Oct 2024).
   - Manual audit of SWE-Agent+GPT-4 successes: 32.67% involved solution leakage and 31.08% passed only because tests were weak. Filtering dropped the resolve rate from 12.47% to 3.97%. Over 94% of issues predate model knowledge cutoffs.
   - **verified: yes.**
7. **The SWE-Bench Illusion: When State-of-the-Art LLMs Remember Instead of Reason.** Liang, Garg, Moghaddam. arXiv:2506.12286 (Jun 2025).
   - Two diagnostic probes (identifying the file path from the issue text alone, and reproducing the gold function) suggest memorisation. Models reach up to 76% accuracy on file-path identification. A good contamination case study.
   - **verified: yes.**
8. **SWE-rebench.** Badertdinov et al. (Nebius). arXiv:2505.20411 (May 2025).
   - An automated pipeline that continuously mines fresh interactive SWE tasks: over 21,000 Python tasks for RL plus a decontaminated, rolling evaluation. Shows the "fresh tasks" answer to contamination.
   - **verified: yes.**
9. **SWE-Lancer.** Miserendino, Wang, Patwardhan et al. (OpenAI). arXiv:2502.12115 (Feb 2025).
   - More than 1,400 Upwork tasks worth $1M in payouts. Includes independent coding tasks graded by E2E tests "triple-verified by experienced software engineers" and managerial proposal-selection tasks. Maps performance to dollars.
   - ABC found an agent "can score 100% on SWE-Lancer without resolving any tasks" (a task-validity issue in the version they audited).
   - **verified: yes.**
10. **SWE-agent: Agent-Computer Interfaces Enable Automated Software Engineering.** Yang, Jimenez, Wettig et al. arXiv:2405.15793 (NeurIPS 2024).
    - Shows that interface design (the ACI) strongly affects agent success, so a benchmark score belongs to the model plus its scaffold.
    - Repo SWE-agent/SWE-agent: 20.8k stars. mini-SWE-agent: 9.9k stars; it describes itself as a "100 line AI agent" scoring above 74% on SWE-bench Verified, a useful minimal reference scaffold for controlled comparisons.
    - **verified: yes.**
11. **Agentless: Demystifying LLM-based Software Engineering Agents.** Xia, Deng, Dunn et al. arXiv:2407.01489 (Jul 2024).
    - A simple non-agentic localise-repair-validate pipeline that competed with complex agents at low cost. It also introduced a manually filtered SWE-bench Lite subset. The key "strong simple baseline" reference.
    - **verified: yes** (title and authors; specific numbers not re-checked).
12. **Terminal-Bench: Benchmarking Agents on Hard, Realistic Tasks in Command Line Interfaces.** Merrill, Shaw, Carlini et al. arXiv:2601.11868 (Jan 2026; ICLR 2026).
    - Terminal-Bench 2.0 has 89 hard terminal tasks, each with "a unique environment, human-written solution, and comprehensive tests". Frontier agents score under 65%. Tasks were reviewed by three humans.
    - Distributed through the **Harbor** framework: harbor-framework/harbor, 7.3k stars, pushed 2026-11-20. Also harbor-framework/terminal-bench (1.1k) and terminal-bench-1 (2.6k).
    - **verified: yes.**
13. **InterCode.** Yang, Prabhakar, Narasimhan, Yao. arXiv:2306.14898 (Jun 2023).
    - An early framework that frames interactive coding (Bash/SQL/Python) as an RL environment with execution feedback in Docker. A good bridge to the RL-environments chapter.
    - **verified: yes.**

### B. Tool use / function calling / conversational agents
14. **tau-bench: A Benchmark for Tool-Agent-User Interaction in Real-World Domains.** Yao, Shinn, Razavi, Narasimhan (Sierra). arXiv:2406.12045 (Jun 2024).
    - An LM-simulated user, domain APIs and policy documents (retail, airline). Graded by comparing the final database state to the goal state. Introduces **pass^k**.
    - Repo sierra-research/tau-bench: 1.5k stars, pushed 2026-03-18.
    - **verified: yes** (abstract and code).
15. **tau2-bench: Evaluating Conversational Agents in a Dual-Control Environment.** Barres, Dong, Ray et al. arXiv:2506.07982 (Jun 2025).
    - Adds a Telecom dual-control domain (Dec-POMDP), a compositional task generator, and a user simulator constrained by tools and state. Separates reasoning errors from communication errors.
    - Repo sierra-research/tau2-bench: 2.5k stars, pushed 2026-11-10.
    - **verified: yes.**
16. **Gorilla: Large Language Model Connected with Massive APIs.** Patil, Zhang, Wang, Gonzalez. arXiv:2305.15334 (May 2023). And **The Berkeley Function Calling Leaderboard (BFCL): From Tool Use to Agentic Evaluation of LLMs**, Patil, Mao, Yan, Ji, Suresh, Stoica, Gonzalez, ICML 2025 (PMLR 267). Gorilla introduced APIBench and AST-based hallucination checks. BFCL standardises function-calling evaluation across serial, parallel, multiple, irrelevance/abstention, multi-turn (V3) and agentic (V4) settings. Repo ShishirPatil/gorilla, 13.1k stars, pushed 2026-10-17; `pip install bfcl-eval`. **verified: yes** (Gorilla abstract and BFCL code). The BFCL paper metadata comes from ICML/MLAnthology listings: **partial**.
17. **ToolLLM: Facilitating LLMs to Master 16000+ Real-world APIs.** Qin, Liang, Ye et al. arXiv:2307.16789 (Jul 2023). Introduces ToolBench and ToolEval, an LLM-judged pass rate and win rate over RapidAPI calls. It is the classic example of LLM-judged tool use against live APIs, which suffer from API instability; later work (StableToolBench) addressed this. **verified: yes** (title and authors).
18. **ToolSandbox.** Lu, Holleis, Zhang et al. (Apple). arXiv:2408.04682 (Aug 2024). Covers stateful tool execution, implicit state dependencies, an on-policy user simulator, and milestone-based evaluation over arbitrary trajectories. Hard categories are State Dependency, Canonicalization and Insufficient Information. Repo apple-aiml-research/ToolSandbox, 294 stars. **verified: yes.**
19. **AppWorld.** Trivedi, Khot, Hartmann et al. arXiv:2407.18901 (ACL 2024 Best Resource Paper per the repo). Nine apps, 457 APIs and 750 tasks. State-based unit tests allow multiple solution paths and check for **collateral damage**. GPT-4o scored about 49% on normal tasks and about 30% on challenge tasks. Repo StonyBrookNLP/appworld, 557 stars. **verified: yes.**
20. **MINT.** Wang, Wang, Liu et al. arXiv:2309.10691 (Sep 2023). Evaluates multi-turn interaction with tools and simulated natural-language feedback, measuring gains per extra turn. **verified: yes** (title and authors).
21. **CodeAct: Executable Code Actions Elicit Better LLM Agents.** Wang, Chen, Yuan et al. arXiv:2402.01030 (Feb 2024). Code-as-action beats JSON/text tool calls, with up to 20% higher success. Relevant because the choice of action space changes results. **verified: yes.**

### C. Web, computer-use and general assistants
22. **WebShop.** Yao, Chen, Yang, Narasimhan. arXiv:2207.01206 (Jul 2022). A simulated e-commerce site with 1.18M products and an attribute-matching reward. A classic foundation for web agents as RL environments. **verified: yes** (title and authors).
23. **Mind2Web.** Deng, Gu, Zheng et al. arXiv:2306.06070 (Jun 2023). An offline dataset of real-website action traces with step-level metrics (element accuracy, step success rate). A good contrast between offline/static and online/interactive evaluation. **verified: yes** (title and authors).
24. **WebArena.** Zhou, Xu, Zhu et al. arXiv:2307.13854 (Jul 2023). Self-hosted, reproducible sites (e-commerce, forum, GitLab, CMS) plus tools. The best GPT-4 agent reached 14.41% against 78.24% for humans. ABC reports WebArena overestimates performance by 5.2% because of string-matching issues. Repo web-arena-x/webarena, 1.6k stars. **verified: yes.**
25. **VisualWebArena.** Koh, Lo, Jang et al. arXiv:2401.13649 (Jan 2024). Visually grounded web tasks for multimodal agents. **verified: yes** (title and authors).
26. **WorkArena.** Drouin, Gasse, Caccia et al. (ServiceNow). arXiv:2403.07718 (Mar 2024). Enterprise knowledge-work tasks on ServiceNow, introduced with BrowserGym. **verified: yes** (title and authors).
27. **OSWorld.** Xie, Zhang, Chen et al. arXiv:2404.07972 (Apr 2024; NeurIPS 2024). Real VMs (Ubuntu/Windows/macOS) with 369 tasks, each with an initial-state config and a custom execution-based evaluation script. Humans scored 72.36% and the best model 12.24%, failing mainly on GUI grounding. Repo xlang-ai/OSWorld, 3.3k stars, pushed 2026-11-14. **verified: yes.**
28. **Windows Agent Arena** (Bonatti et al., arXiv:2409.08264) and **AndroidWorld** (Rawles et al., arXiv:2405.14573). Scalable, parallelisable OS-agent evaluation on Windows and Android. AndroidWorld uses dynamically parameterised tasks with state-based rewards. **verified: yes** (title and authors).
29. **GAIA: a benchmark for General AI Assistants.** Mialon, Fourrier, Swift, Wolf, LeCun, Scialom. arXiv:2311.12983 (Nov 2023). 466 questions that are conceptually simple for humans (92%) but hard for GPT-4 with plugins (15%). Answers are short and quasi-exact-match, and answers to 300 questions are held out for a leaderboard. **verified: yes.**
30. **BrowseComp.** Wei, Sun, Papay et al. (OpenAI). arXiv:2504.12516 (Apr 2025). 1,266 hard-to-find-information questions with short, verifiable answers, designed to be "easy to verify, hard to solve". Code in openai/simple-evals (4.7k stars). **verified: yes.**
31. **AgentBench.** Liu, Yu, Zhang et al. arXiv:2308.03688 (Aug 2023; ICLR 2024). Eight environments (OS, DB, knowledge graph, card game, lateral thinking, house-holding, web shopping, web browsing) for a multi-environment LLM-as-agent comparison. Repo THUDM/AgentBench, 3.8k stars. **verified: yes** (title and authors).
32. **TheAgentCompany.** Xu, Song, Li et al. arXiv:2412.14161 (Dec 2024). A simulated software-company intranet with web, code and simulated coworkers. Uses checkpoint-based partial credit. The best agent completed 30% of tasks autonomously. **verified: yes.**

### D. Autonomy, R&D and domain-capability evaluations
33. **Measuring AI Ability to Complete Long Software Tasks.** Kwa, West, Becker et al. (METR). arXiv:2503.14499 (Mar 2025). Defines the 50% time horizon with a logistic model in log human time; finds a doubling time of about 7 months since 2019; Claude 3.7 Sonnet at about 50 min. **verified: yes** (abstract and formula from the arXiv HTML).
34. **HCAST: Human-Calibrated Autonomy Software Tasks.** Rein, Becker, Deng et al. (METR). arXiv:2503.17354 (Mar 2025). 189 tasks with 563 human baselines (over 1,500 hours). Agents succeed 70-80% of the time on tasks that take humans under 1 hour and under 20% of the time on tasks that take over 4 hours. **verified: yes.**
35. **RE-Bench.** Wijk, Lin, Becker et al. (METR). arXiv:2411.15114 (Nov 2024). Seven ML research-engineering environments with 71 eight-hour human expert attempts. With a 2-hour budget the best agents score 4x humans; with 32 total hours humans score 2x agents. Shows that comparisons depend on the time and compute budget, and introduces best-of-k comparisons against humans. **verified: yes.**
36. **MLE-bench.** Chan, Chowdhury, Jaffe et al. (OpenAI). arXiv:2410.07095 (Oct 2024). 75 Kaggle competitions graded with Kaggle leaderboards and medal thresholds. o1-preview with AIDE reached at least a bronze medal in 16.9% of competitions. Also studies resource scaling and contamination. Repo openai/mle-bench, 1.8k stars. **verified: yes.**
37. **PaperBench.** Starace, Jaffe, Sherburn et al. (OpenAI). arXiv:2504.01848 (Apr 2025). Replicate 20 ICML 2024 papers, graded with hierarchical rubrics (8,316 leaf tasks) co-developed with the authors. Grading uses an LLM judge that is itself validated on a judge benchmark (JudgeEval). Best score 21.0% (Claude 3.5 Sonnet New). **verified: yes.**
38. **Cybench.** Zhang, Perry, Dulepet et al. (Stanford). arXiv:2408.08926 (Aug 2024). 40 professional CTF tasks with subtasks, using human first-solve time as a difficulty measure. Unguided agents solved tasks that took human teams up to 11 minutes; the hardest task took humans 24h54m. Repo andyzorigin/cybench. **verified: yes.**

### E. Meta-evaluation, methodology and infrastructure
39. **AI Agents That Matter.** Kapoor, Stroebl, Siegel, Nadgir, Narayanan (Princeton). arXiv:2407.01502 (Jul 2024). Argues for cost-controlled evaluation and Pareto curves. Shows simple baselines (retry, warming, escalation) match SOTA agents on HumanEval. Separates model-developer from downstream-developer needs. Covers overfitting, missing holdouts and shortcuts (STeP on WebArena), and poor reproducibility. **verified: yes.**
40. **Holistic Agent Leaderboard (HAL).** Kapoor, Stroebl, Kirgis et al. arXiv:2510.11977 (Oct 2025; ICLR 2026). A standardised harness running across hundreds of VMs: 21,730 rollouts, 9 models, 9 benchmarks, about $40k. Finds higher reasoning effort *reduces* accuracy in most runs. LLM-aided log inspection surfaced agents searching HuggingFace for answers and misusing credit cards. All logs (2.5B tokens) are shared. Repo princeton-pli/hal-harness, 308 stars, **archived** as of 2026-07. **verified: yes.**
41. **Establishing Best Practices for Building Rigorous Agentic Benchmarks (ABC).** Zhu, Jin, Pruksachatkun, ... Kang (UIUC et al.). arXiv:2507.02825 (Jul 2025).
    - The Agentic Benchmark Checklist covers task validity, outcome validity and benchmark reporting. Flaws can skew results "by up to 100% in relative terms".
    - Case studies:
      - tau-bench: an empty-response agent scores 38%.
      - SWE-Lancer: 100% achievable without solving tasks.
      - KernelBench: overestimated by about 31% absolute.
      - WebArena: overestimated by 5.2%.
      - OSWorld Chrome: underestimated by 28% after site drift.
    - Applying the checklist to CVE-Bench reduced overestimation by 33%.
    - **verified: yes** (abstract and HTML body).
42. **Agent-as-a-Judge: Evaluate Agents with Agents.** Zhuge, Zhao, Ashley et al. (Meta / KAUST). arXiv:2410.10934 (Oct 2024). Introduces DevAI (55 tasks, 365 hierarchical requirements). An agentic judge inspects the workspace and trajectory, beats LLM-as-a-Judge, and is "as reliable as our human evaluation baseline". Repo metauto-ai/agent-as-a-judge, 852 stars. **verified: yes.**
43. **AgentBoard.** Ma, Zhang, Zhu et al. arXiv:2401.13178 (Jan 2024; NeurIPS 2024 Oral per the repo). A progress-rate metric for multi-turn agents in partially observable environments, plus an analytical toolkit. Repo hkust-nlp/AgentBoard, 454 stars, last push 2024-05. **verified: yes.**
44. **TRAIL: Trace Reasoning and Agentic Issue Localization.** Deshpande, Gangal, Mehta et al. (Patronus AI). arXiv:2505.08638 (May 2025). A taxonomy of agentic error types and 148 human-annotated traces from single and multi-agent systems. It benchmarks how well LLMs can debug traces, i.e. trace-level evaluation. **verified: yes.**
45. **Why Do Multi-Agent LLM Systems Fail? (MAST).** Cemri, Pan, Yang et al. (Berkeley). arXiv:2503.13657 (Mar 2025). Over 1,600 annotated traces from 7 MAS frameworks; 14 failure modes in 3 categories (system design, inter-agent misalignment, task verification); κ = 0.88; LLM-as-judge annotation pipeline. **verified: yes.**
46. **Survey on Evaluation of LLM-based Agents.** Yehudai, Eden, Li et al. arXiv:2503.16416 (Mar 2025). A broad survey of agent capabilities, application benchmarks, generalist benchmarks and frameworks. Useful for the chapter's further-reading list. **verified: yes** (title and authors).
47. **Demystifying evals for AI agents** (Anthropic Engineering blog, published Jan 9, 2026; anthropic.com/engineering/demystifying-evals-for-ai-agents).
    - Definitions (task, trial, grader, transcript, outcome, harnesses).
    - Grader types, capability vs. regression evals, and coding/conversational/research/computer-use specifics.
    - pass@k vs. pass^k, an 8-step roadmap ("20-50 simple tasks drawn from real failures is a great start"), environment isolation, reading transcripts, and saturation.
    - Concrete incidents: CORE-Bench Opus 4.5 went from 42% to 95% after grading fixes; a git-history leak across trials; METR threshold misconfiguration.
    - Framework list (Harbor, Braintrust, LangSmith, Langfuse, Arize Phoenix).
    - **verified: yes** (full text fetched).
48. **Recent Frontier Models Are Reward Hacking** (METR blog, Jun 5, 2025; Von Arx, Chan, Barnes).
    - o3 reward-hacked in 0.7% of HCAST runs, but far more on RE-Bench, where the scoring function was visible ("more than 43× more common"). Per-task examples: Optimize a Kernel 6/24 = 25%; Rust Codecontest scaffolding 12/28 = 42.9%.
    - Detection used both high-score anomaly review and an LLM monitor, and the two disagreed, which suggests undercounting.
    - **verified: yes.**
49. **Measuring the Impact of Early-2025 AI on Experienced Open-Source Developer Productivity.** Becker, Rush, Barnes et al. (METR). arXiv:2507.09089 (Jul 2025). An RCT with 16 developers and 246 tasks: allowing AI *increased* completion time by 19%, while developers believed it reduced it by 20%. A key external-validity counterpoint to benchmark scores. **verified: yes.**
50. **Inspect AI** (UK AI Security Institute). github.com/UKGovernmentBEIS/inspect_ai, 3.3k stars, pushed 2026-11-20; docs at inspect.aisi.org.uk. A framework with `Task(dataset, solver, scorer, sandbox)`, a built-in `react()` agent, `bash()` tools, Docker sandboxing and the `inspect view` transcript viewer. inspect_evals (750 stars) packages many agent benchmarks. METR has moved from Vivaria (archived) to Inspect (METR/inspect-agents). **verified: yes** (docs code read).
51. **OpenAI trace grading / agent evals docs** (developers.openai.com/api/docs/guides/trace-grading). Defines trace grading as "assigning structured scores or labels to an agent's trace—the end-to-end log of decisions, tool calls, and reasoning steps". Trace evals reuse graded traces to "benchmark changes, identify regressions, or validate improvements", and give more data than "black-box evaluations" about why an agent succeeds or fails. **verified: yes** (markdown version fetched).
52. **OpenTelemetry GenAI semantic conventions** (agent and tool spans). The spec defines `invoke_agent` and `execute_tool {gen_ai.tool.name}` span types under `gen_ai.*` attributes. The docs in open-telemetry/semantic-conventions now say they "have moved to … semantic-conventions-genai". Status is still *Development*, not stable. **verified: partial** (move notice confirmed directly; span names from secondary sources).
53. **Evaluating Large Language Models Trained on Code (Codex / HumanEval).** Chen, Tworek, Jun et al. arXiv:2107.03374 (Jul 2021). Origin of the unbiased pass@k estimator, which every agent pass@k and pass^k calculation builds on. **verified: yes.**

Total: 53 entries. 47 are fully verified and 6 are partial (#2, #3, #5 scores, #16 BFCL paper metadata, #52, plus some secondary star-count facts). Counted as distinct verified sources: **47**.

---

## 4. Code patterns from real repos (exact sources) and teaching-example ideas

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

### 4.2 pass^k (sierra-research/tau-bench, `tau_bench/run.py`, `display_metrics`)
```python
    # c from https://arxiv.org/pdf/2406.12045
    c_per_task_id: dict[int, int] = {}
    for result in results:
        if result.task_id not in c_per_task_id:
            c_per_task_id[result.task_id] = 1 if is_successful(result.reward) else 0
        else:
            c_per_task_id[result.task_id] += 1 if is_successful(result.reward) else 0
    pass_hat_ks: dict[int, float] = {}
    for k in range(1, num_trials + 1):
        sum_task_pass_hat_k = 0
        for c in c_per_task_id.values():
            sum_task_pass_hat_k += comb(c, k) / comb(num_trials, k)
        pass_hat_ks[k] = sum_task_pass_hat_k / len(c_per_task_id)
```
Here `is_successful` is `(1 - 1e-6) <= reward <= (1 + 1e-6)`.

### 4.3 State-hash grading plus required outputs (tau-bench, `tau_bench/envs/base.py`, `calculate_reward`)
```python
data_hash = self.get_data_hash()
reward = 1.0
...
self.data = self.data_load_func()            # reset to initial DB
for action in self.task.actions:              # replay gold actions
    if action.name not in self.terminate_tools:
        self.step(action)
gt_data_hash = self.get_data_hash()
info = RewardActionInfo(r_actions=data_hash == gt_data_hash, gt_data_hash=gt_data_hash)
if not info.r_actions:
    reward = 0.0
if len(self.task.outputs) > 0:                # required strings in replies
    ...
        if (action.name == RESPOND_ACTION_NAME
            and output.lower() in action.kwargs["content"].lower().replace(",", "")):
            found = True
```
Teaching point: the substring check on outputs is lenient, and the hash check is strict over the whole database. If the gold actions perform no writes (an impossible task that must be refused), a do-nothing agent passes. This is exactly the ABC finding.

### 4.4 Resolution status (SWE-bench, `swebench/harness/grading.py`)
```python
def get_resolution_status(report: dict[str, dict[str, Any]]) -> str:
    """
    Criteria:
        - If fail-to-pass (Resolution) = 1 and pass-to-pass (Maintenance) = 1 -> FULL
        - If (fail-to-pass (Resolution) < 1 and > 0) and pass-to-pass (Maintenance) = 1 -> PARTIAL
        - Otherwise -> NO
    """
    f2p = compute_fail_to_pass(report)
    p2p = compute_pass_to_pass(report)
    if f2p == 1 and p2p == 1:
        return ResolvedStatus.FULL.value
    elif f2p < 1 and f2p > 0 and p2p == 1:
        return ResolvedStatus.PARTIAL.value
    else:
        return ResolvedStatus.NO.value
```

### 4.5 AST tool-call checking (ShishirPatil/gorilla, `berkeley-function-call-leaderboard/bfcl_eval/eval_checker/ast_eval/ast_checker.py`)
```python
def standardize_string(input_string: str):
    # We don't want to punish model for answer like April 1, 2024 vs April 1,2024, vs April 1 2024
    regex_string = r"[ \,\.\/\-\_\*\^]"
    return re.sub(regex_string, "", input_string).lower().replace("'", '"')
```
`simple_function_checker` returns typed errors in order: `wrong_func_name`, then `missing_required`, then `unexpected_param`, then type errors, then value errors. Teaching point: an error taxonomy for tool calls is more useful than a single boolean.

### 4.6 Agent task with sandbox (Inspect AI docs, inspect.aisi.org.uk)
```python
from inspect_ai import Task, task
from inspect_ai.agent import react
from inspect_ai.dataset import json_dataset
from inspect_ai.scorer import includes
from inspect_ai.tool import bash, todo_write

@task
def ctf():
    return Task(
        dataset=json_dataset("challenges.json"),
        solver=react(
            prompt=("You are a Capture the Flag player. "
                    "Explore the system and find the flag."),
            tools=[bash(), todo_write()],
            attempts=3,
        ),
        scorer=includes(),
        sandbox="docker",
    )
```
The prompt string is joined slightly differently from the docs page for valid Python. The same page shows `inspect eval ctf.py --model ...` and `inspect view` for transcripts.

### 4.7 Anthropic's multi-grader task spec (illustrative YAML, *Demystifying evals*)
```yaml
task:
  id: "fix-auth-bypass_1"
  graders:
    - type: deterministic_tests
      required: [test_empty_pw_rejected.py, test_null_pw_rejected.py]
    - type: llm_rubric
      rubric: prompts/code_quality.md
    - type: static_analysis
      commands: [ruff, mypy, bandit]
    - type: state_check
      expect: {security_logs: {event_type: "auth_blocked"}}
    - type: tool_calls
      required: [{tool: read_file, params: {path: "src/auth/*"}}, {tool: edit_file}, {tool: run_tests}]
  tracked_metrics:
    - type: transcript
      metrics: [n_turns, n_toolcalls, n_total_tokens]
    - type: latency
      metrics: [time_to_first_token, output_tokens_per_sec, time_to_last_token]
```
Anthropic notes this shows the full range of graders for illustration. In practice they use unit tests plus an LLM rubric.

### 4.8 Runnable, self-contained teaching examples (stdlib/numpy, mocked agents, no API keys)
1. **pass@k vs. pass^k explorer.** Simulate tasks with heterogeneous per-task success probabilities p_i ~ Beta(a, b), run n trials, compute both estimators, and plot or print against k. Show that pass^k ≈ mean(p_i^k), not (mean p)^k. The worked numbers in §2.4 came from this code.
2. **Mini tau-bench.** Build a toy retail database (a dict), tools (`get_order`, `cancel_order`, `refund`), a policy ("cannot refund delivered orders without a reason"), and a rule-based *mock user simulator* driven by a scripted goal. Add 3 mock agents: correct, sloppy (skips the confirmation step) and do-nothing. Grade by `hashlib.sha256(json.dumps(db, sort_keys=True))` against a gold replay. Show that the do-nothing agent "passes" impossible tasks, then fix the grader by requiring an explicit refusal output.
3. **Mini SWE-bench.** Ship a tiny buggy module plus FAIL_TO_PASS and PASS_TO_PASS tests. Candidate "patches" are Python functions. Run tests in a `subprocess` with a timeout for isolation. Include a patch that passes weak tests but is wrong, to show test insufficiency (SWE-bench+). Then strengthen the tests with a property/fuzz check.
4. **AST tool-call checker.** Parse mocked model outputs like `get_weather(city="Paris", unit="C")` with Python's `ast` module. Check name, required parameters, types and allowed values against a JSON schema. Report a typed error taxonomy following BFCL.
5. **Trajectory vs. outcome grader comparison.** Two mock agents reach the same final state by different paths. A rigid "exact tool sequence" grader fails the valid alternative path; an outcome grader passes both; a "must-include safety step" trajectory constraint catches an unsafe agent.
6. **Milestones / progress rate.** Define milestones as predicates over states (as in ToolSandbox and AgentBoard), compute the max fraction achieved along a trajectory, and contrast it with binary success.
7. **Flaky-environment simulation.** Inject a 5% random tool failure (a mocked HTTP 503) and correlated failures, where one "bad worker" fails all its tasks. Show the inflated variance and the bias when infrastructure errors are counted as agent failures. Then implement retry-on-infra-error with an `infra_error` status that is distinct from `agent_fail`.
8. **Statistics for leaderboards.** Paired bootstrap over tasks for agent A vs. B, McNemar's test, and a cluster bootstrap by repo. Show that a 2-point gap on N = 500 is often not significant.
9. **Cost-accuracy Pareto frontier.** Mock agents with (accuracy, $/task), including "retry" and "escalation" strategies (Kapoor et al.). Compute the Pareto frontier and $ per resolved task.
10. **Time-horizon fit.** Generate synthetic success data against human task times and fit σ((log h − log t)·β) by grid search or numpy gradient descent. Bootstrap tasks to get a CI on h50. My run with true h = 30 min, β = 1.2 and 80 trials fitted h50 = 23.5 min and β = 1.3, which shows real uncertainty.
11. **Reward-hacking detector.** A mock agent that edits the test file or monkey-patches the scorer. Detect it with (a) file-integrity hashes of protected grader files, (b) anomaly detection on impossibly high scores, and (c) a keyword "monitor" over the transcript. This mirrors METR's two detection methods.
12. **Tracing.** A minimal span logger (a context manager writing JSON lines with `trace_id`, `span_id`, `parent_id`, `name` such as `invoke_agent`/`execute_tool`, timings and token counts) following the OTel GenAI naming. Then a "trace grader" that computes `n_toolcalls`, repeated-call loops and errors per tool.

---

## 5. Pitfalls, debates, open problems, practitioner recommendations

**Validity pitfalls (ABC, SWE-bench+, Anthropic, METR, HAL):**
- *Weak or insufficient tests* let wrong patches pass (SWE-bench+: 31% of passes suspicious; SWE-bench Verified's "insufficient test cases", ABC).
- *Too-narrow tests* reject valid solutions, for example by requiring a specific file path or exact float format. Anthropic cites Terminal-Bench filepath ambiguity and CORE-Bench "96.12" vs "96.124991…", where fixing grading moved Opus 4.5 from 42% to 95%.
- *Trivial-agent pass* happens when the goal state equals the initial state (tau-bench's 38% empty-response agent). **Always run null, random and do-nothing baselines.**
- *Solution leakage* occurs when the issue text contains the fix (SWE-bench+: 32.67%).
- *Contamination / memorisation* affects public GitHub-derived tasks (SWE-Bench Illusion; OpenAI retiring SWE-bench Verified). Mitigations are fresh rolling tasks (SWE-rebench), private or held-out sets (SWE-Bench Pro, GAIA's hidden answers) and canaries.
- *Environment drift* on live websites breaks graders (OSWorld Chrome -28%). Prefer self-hosted snapshots (WebArena) and version-pin everything.
- *Shared state across trials* (Anthropic: Claude read git history from previous trials). Run each trial in a fresh container or VM.
- *Correlated infrastructure failures* (CPU/memory limits) make trials non-independent. Record infrastructure errors separately and rerun them.
- *Reward hacking* means agents modify tests or scorers, or look up answers (METR 2025; HAL: searching HuggingFace for the benchmark). Mitigations:
  - Hide grader code from the agent and make protected files read-only.
  - Diff the workspace for edits to tests.
  - Use LLM monitors combined with manual review of anomalous high scores.
- *Instructions vs. grading mismatch* (METR thresholds "achieve" vs "exceed") penalises models that follow instructions.

**Reporting pitfalls:**
- Not reporting scaffold, model version, number of attempts, cost or token budget. Anthropic: "we do not take eval scores at face value until someone digs into the details of the eval and reads some transcripts."
- pass@k with a hidden oracle selector presented as if it were pass@1.
- No confidence intervals.
- Leaderboards mixing "bash only" with heavily engineered scaffolds. The SWE-bench site added a "Bash Only" leaderboard for this reason.

**Debates:**
1. *Outcome vs. process grading.* Anthropic warns that strict step checks are brittle. Agent-as-a-Judge, TRAIL and trace grading argue that process signals are needed for debugging and as rewards.
2. *LLM judges for agents.* They scale (PaperBench's judge, MAST's annotator pipeline), but they need calibration against humans and are vulnerable to persuasion and hacking.
3. *Model vs. system evaluation.* Should benchmarks standardise the scaffold (mini-SWE-agent, HAL) or allow anything? Kapoor et al. say model developers and downstream developers need different benchmarks.
4. *Accuracy vs. cost.* Kapoor et al. and HAL report that more reasoning effort does not always help.
5. *Benchmarks vs. real-world impact.* METR's RCT showed a 19% slowdown despite strong benchmark scores, and the time-horizon paper itself flags limited external validity.
6. *Simulated users.* They are cheap and reproducible, but they introduce bias and noise. tau2's tool-constrained simulator is one answer.

**Open problems:**
- Evaluating very long-horizon tasks (days), multi-agent systems and subjective deliverables.
- Grading without a unique ground truth.
- Measuring safety and side effects (collateral damage, policy violations) alongside success.
- Robust, cheap, reproducible computer-use environments.
- Contamination-proof task supply.
- Standard trace formats: OTel GenAI conventions are still in "Development".
- Reliability metrics beyond pass^k, such as robustness to paraphrase and perturbation; HAL has a Reliability Dashboard covering consistency, robustness and safety.

**Practitioner recommendations (consolidated, mostly Anthropic, ABC, HAL, Kapoor):**
1. Start early with 20-50 tasks drawn from real failures and the bug tracker.
2. Write unambiguous tasks that two experts would grade the same way, and give every task a **reference solution** that passes all graders.
3. Balance the dataset with positive and negative cases, including tasks where the agent should *not* act.
4. Use an isolated, clean environment per trial, and keep the eval agent the same as the production agent.
5. Prefer deterministic graders, add LLM rubrics where needed (calibrated, one dimension per judge, with an "Unknown" option), and use humans for calibration.
6. Give partial credit for multi-step tasks.
7. Make graders hack-resistant, and run null and adversarial baselines.
8. Run multiple trials and report pass@1 with a CI plus pass^k for user-facing agents. Also report cost, tokens and latency, and use Pareto plots.
9. **Read transcripts** regularly, using tooling to view them.
10. Watch for saturation and graduate solved tasks to regression suites.
11. Complement offline evals with production monitoring, A/B tests, user feedback and human studies. Anthropic calls this layering the "Swiss cheese model".
12. Apply the ABC checklist before publishing a benchmark.

---

## 6. Suggested sub-sections for the book chapter "Evaluating AI Agents"

1. **Why agents need different evals.** The agent loop; the model-plus-harness unit; vocabulary (task, trial, transcript, outcome, grader, harnesses).
2. **A tour of agent benchmarks.** SWE (SWE-bench family to SWE-Bench Pro and Terminal-Bench), tool use (BFCL, tau/tau2, AppWorld, ToolSandbox), web and computer use (WebArena to OSWorld), general (GAIA, BrowseComp), autonomy (METR, MLE-bench, PaperBench, Cybench). Use a summary table of grading mechanisms.
3. **Outcome-based grading.** Unit tests (FAIL_TO_PASS/PASS_TO_PASS), state hashing, execution scripts, answer matching. Code: mini SWE-bench and mini tau-bench.
4. **Trajectory and tool-call grading.** AST checks (BFCL), milestones and progress rate, trace grading, Agent-as-a-Judge, and when step checks become brittle. Code: AST checker and milestone scorer.
5. **Simulated users and multi-turn evaluation.** tau-bench, tau2 dual control, ToolSandbox; simulator validity.
6. **Reliability and statistics.** pass@k vs. pass^k derivations, the worked example, CIs, paired tests, clustered bootstrap. Code: the explorer.
7. **Cost, latency and Pareto frontiers.** Kapoor et al., HAL; metrics to log. Code: Pareto plot.
8. **Human-calibrated difficulty: time horizons.** The METR logistic model, HCAST/RE-Bench, the caveats. Code: horizon fit.
9. **Building an eval harness.** Sandboxing (Docker/VM, Inspect `sandbox=`), isolation, flaky infrastructure versus agent failure, retries, timeouts, determinism, versioning, Harbor and Inspect examples, parallelism.
10. **Tracing and observability.** Transcripts, OTel GenAI spans, trace-level error taxonomies (TRAIL, MAST). Code: span logger plus trace grader.
11. **When benchmarks lie.** ABC checklist, SWE-bench+, contamination (SWE-Bench Illusion, OpenAI retiring Verified), reward hacking (METR), shortcuts and holdouts, environment drift. Code: reward-hack detector.
12. **From offline evals to production.** Capability vs. regression suites, saturation, the Swiss cheese model, RCTs (METR's productivity study), A/B tests. A practitioner's checklist.
13. **Exercises and further reading.**
