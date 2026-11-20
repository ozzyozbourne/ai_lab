# Chapter 7 code: RL Environments: Rewards, Verifiers and Reward Hacking

Standard library + NumPy only. No gym/gymnasium install, no network, no API keys: every environment, policy,
verifier and judge is a seeded mock, and the tabular RL is plain NumPy.
Run any file from any directory, or all of them with `python3 code/run_all.py ch07`.
Every script asserts the numbers quoted in the chapter, so a passing run means the text and the code agree.

| File | Section | What it shows | Command |
|---|---|---|---|
| `gridworld_env.py` | 7.2 `#interface` | Gymnasium-style 5-tuple GridWorld with env-owned RNG, time limit -> `truncated`; `BuggyGridWorld` with three seeded bugs; TD(0) on a never-ending task: `(1 - terminated)` gives V = 10.00, `(1 - done)` gives 5.26 | `python3 code/ch07/gridworld_env.py` |
| `mini_check_env.py` | 7.2 `#interface` | a 7-check mini `check_env` (seed determinism, step determinism, obs in space, types, time limit truncates); GridWorld 7/7, BuggyGridWorld 4/7 | `python3 code/ch07/mini_check_env.py` |
| `text_env.py` | 7.3 `#llm-envs` | multi-turn calculator-tool environment with `env_response` / `is_completed`, a turn limit, and `Rubric(funcs, weights)` with zero-weight logged metrics; careful 1.300, mental 0.975, rambler 0.100 | `python3 code/ch07/text_env.py` |
| `grpo_signal.py` | 7.4 `#rlvr`, Fig 7.4 | GRPO advantages; signal fraction 1 - p^G - (1-p)^G (0.992 / 0.832 / 0.337 at G = 8) with Monte Carlo check; pass-rate band filtering lifts useful batch share 51.0% -> 90.2% | `python3 code/ch07/grpo_signal.py` |
| `robust_extraction.py` | 7.4 `#rlvr` | substring / first-number / strict exactly-one-boxed + cascade verifiers on 14 labelled responses: 6 FP + 3 FN, 2 FP + 5 FN, 0 + 0 | `python3 code/ch07/robust_extraction.py` |
| `coastrunners_lite.py` | 7.5 `#reward-hacking`, Fig 7.5 | tabular Q-learning on a respawning-checkpoint proxy: proxy 4 -> 19 while true return 1 -> 0 after ~800 episodes; pay-once fix | `python3 code/ch07/coastrunners_lite.py` |
| `hackable_verifier.py` | 7.5 `#reward-hacking` | strategies solve / guess / spray / leak vs substring, any-boxed, strict verifiers; impossible-variant cheating rates; REINFORCE over strategies finds the hack unless the verifier is strict and the metadata is stripped | `python3 code/ch07/hackable_verifier.py` |
| `validate_env.py` | 7.6 `#env-qa`, Fig 7.6 | gold, no-op, determinism, leakage, mutation, kitchen-sink spam and difficulty-band checks over 11 tasks with 8 seeded bugs; 8/11 flagged (the substring grader t10 only by the spam probe) | `python3 code/ch07/validate_env.py` |
| `isolation_bug.py` | 7.6 `#env-qa` | shared working directory: pass@1 1.000 vs 0.280 with a fresh `TemporaryDirectory` per trial; leak via trial logs climbs 0.30 -> 0.93 | `python3 code/ch07/isolation_bug.py` |
| `procgen_split.py` | 7.7 `#policy-eval` | seeded perfect mazes, 200 train / 500 held-out levels: memoriser 1.000 vs 0.032; reactive 0.995 vs 0.984; sticky actions p = 0.25; Wilson CIs; normalised return | `python3 code/ch07/procgen_split.py` |
| `rliable_numpy.py` | 7.8 `#few-runs` | IQM, optimality gap, stratified bootstrap CIs, performance profiles, P(improvement); mean vs median vs IQM ranking accuracy at 3 / 5 / 10 seeds; 3-seed minimum detectable gap 2.29 SD (normal approx) vs 3.07 SD (simulated t-test) | `python3 code/ch07/rliable_numpy.py` |
| `passk_crossover.py` | 7.9 `#llm-policy-metrics`, Fig 7.7 | base vs RL-sharpened mock: pass@1 0.170 vs 0.374, crossover at k = 26, pass@256 0.687 vs 0.540; pass^k | `python3 code/ch07/passk_crossover.py` |
| `infra_vs_model_failure.py` | 7.10 `#at-scale` | judge timeouts (10%, more on long answers): timeout -> 0 reports 0.622 vs true 0.697; exclude, retry and raise; 9.6% of correct rollouts get reward 0 | `python3 code/ch07/infra_vs_model_failure.py` |

`mini_check_env.py` imports `gridworld_env.py` from the same folder (it adds its own directory to `sys.path`).
The slowest file, `coastrunners_lite.py` (40 Q-learning runs of 1,500 episodes), takes about 4 s.
