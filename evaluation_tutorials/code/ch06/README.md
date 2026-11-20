# Chapter 6 code: Evaluating AI Agents

Standard library + NumPy only. No network, no API keys: every agent, user simulator, tool backend and environment
is a seeded mock. Two scripts (`mini_swebench.py`, `reward_hack_detector.py`) run candidate code in a separate
`python3 -I` subprocess inside a temporary directory, with a timeout, to imitate per-trial sandboxing.
Run any file from any directory, or all of them with `python3 code/run_all.py ch06`.

| File | Section | What it shows | Command |
|---|---|---|---|
| `mini_swebench.py` | 6.3 `#outcome` | FAIL_TO_PASS / PASS_TO_PASS grading in temp dirs with a 2 s timeout; FULL / PARTIAL / NO; a "no-sort" patch is FULL under weak tests and PARTIAL (not resolved) once a seeded property test is added | `python3 code/ch06/mini_swebench.py` |
| `mini_taubench.py` | 6.3 `#outcome`, Fig 6.2 | dict retail DB, three tools, policy, scripted user; sha256 state hash vs gold replay plus required outputs; do-nothing agent 40% -> 0% once a refusal is required; confirm-before-write trajectory check | `python3 code/ch06/mini_taubench.py` |
| `ast_tool_checker.py` | 6.4 `#trajectory` | BFCL-style AST checking of `get_weather(...)` calls with a typed error taxonomy (4/12 valid) | `python3 code/ch06/ast_tool_checker.py` |
| `trajectory_vs_outcome.py` | 6.4 `#trajectory` | strict / unordered / subset / superset trajectory match vs outcome vs outcome + ordering constraint, on four agents | `python3 code/ch06/trajectory_vs_outcome.py` |
| `milestones.py` | 6.4 `#trajectory` | ordered milestones over states and progress rate; two agent versions with equal success (0.172 vs 0.176) but different progress (0.502 vs 0.601); AgentBoard's unordered max-over-states progress and a ToolSandbox-style minefield (a text to the wrong number zeroes a "success") | `python3 code/ch06/milestones.py` |
| `user_sim_noise.py` | 6.5 `#user-sim` | imports `mini_taubench.py`; simulator drops a constraint or leaves early with probability eps in {0, .05, .1, .2}; correct agent 100% -> 88.6% (all simulator-caused, SD 0 -> 4.5 pts), sloppy 60% -> 56%; clean-replay audit of failure causes | `python3 code/ch06/user_sim_noise.py` |
| `passk_explorer.py` | 6.6 `#reliability`, Fig 6.3 | worked example c = 8, 6, 2, 0 of n = 8: pass^2 = 0.393, pass@2 = 0.607; heterogeneity: pass^k tracks mean(p^k) not (mean p)^k | `python3 code/ch06/passk_explorer.py` |
| `agent_leaderboard_stats.py` | 6.6 `#reliability` | +/-4.3 pt CI at N = 500; unpaired vs paired vs paired bootstrap vs repo-cluster bootstrap; McNemar; power of a true 2-pt gap (McNemar 13.4%, cluster bootstrap 15.5%); Exercise 6.5 options `--repos R --per-repo K --trials T` (25x80: cluster SE 3.06, cluster power 40.4%; 100x20: cluster SE 1.69, power 49.8%; `--trials 4`: per-task means of 4 trials, McNemar skipped, cluster SE 3.62, power 36.8%) | `python3 code/ch06/agent_leaderboard_stats.py` |
| `pareto.py` | 6.7 `#cost`, Fig 6.4 | retry / escalation baselines vs a fixed-cost "complex agent" with common random numbers shared by all strategies; $/resolved task; Pareto frontier (strong retry5 0.857 at $0.063 dominates the complex agent 0.790 at $0.32); `--fooled 0.5` for Exercise 6.4 (complex agent unchanged at 0.790, retry strategies collapse) | `python3 code/ch06/pareto.py` |
| `time_horizon.py` | 6.8 `#time-horizon`, Fig 6.5 | METR logistic in log2 human time fit by gradient descent; true h50 = 30 min, fit 20.5 min, bootstrap CI 13.0-32.7; doubling-time fit | `python3 code/ch06/time_horizon.py` |
| `flaky_env.py` | 6.9 `#harness` | 5% random 503s + correlated bad workers; naive scoring biased by -7.8 pts with 2x the rerun SD; `infra_error` + retry recovers the truth | `python3 code/ch06/flaky_env.py` |
| `span_logger.py` | 6.10 `#tracing` | context-manager span logger to JSONL with OTel GenAI-style names; trace grader for tool counts, loops, errors | `python3 code/ch06/span_logger.py` |
| `reward_hack_detector.py` | 6.11 `#validity` | test editing, scorer overwrite and in-memory monkey-patching vs protected-file hashes, canary + isolated re-grade, and a transcript keyword monitor | `python3 code/ch06/reward_hack_detector.py` |

Every script asserts the numbers quoted in the chapter, so a passing run means the text and the code agree.
