# Chapter 8 code: Safety Evals, Red-Teaming and Dangerous Capabilities

Standard library + NumPy only. No network, no API keys, no real harmful content: every attacker,
target, judge, agent and environment is a seeded mock, and every "behaviour" is a placeholder
such as `BEHAVIOUR_017`. Run any file from any directory, or all of them with
`python3 code/run_all.py ch08`. Shared helpers (Wilson, kappa, McNemar, AUC) are in `_common.py`.

| File | Section | What it shows | Command |
|---|---|---|---|
| `three_judges.py` | 8.3 `#harm-judges` | refusal-substring vs HarmBench-rules classifier vs StrongREJECT rubric on 400 mock responses: ASR 0.448 vs 0.305 vs 0.264 (truth 0.270), kappa 0.081 vs 0.842 | `python3 code/ch08/three_judges.py` |
| `pair_loop.py` | 8.4 `#red-teaming`, Fig 8.2 | PAIR-style attacker/target/judge loop with query accounting; 0.910 vs random search 0.425 at 20 queries; budget curves cross | `python3 code/ch08/pair_loop.py` |
| `bon_scaling.py` | 8.5 `#asr`, Fig 8.3 | best-of-N with p_b ~ Beta(0.3, 6): ASR@100 0.995 homogeneous vs 0.608 heterogeneous; slope 0.487; BoN power-law forecast; stopping-judge false positives (f = 0.002 lifts ASR@1000 from 0.800 to 0.973) | `python3 code/ch08/bon_scaling.py` |
| `asr_stats.py` | 8.5 `#asr` | Wilson CIs, z-test (12% vs 18%: p = 0.235), exact McNemar (p = 0.180 vs 0.031), universal vs per-behaviour jailbreaks | `python3 code/ch08/asr_stats.py` |
| `over_refusal_roc.py` | 8.6 `#over-refusal`, Fig 8.4 | XSTest refusal_rate worked example (12%); threshold sweep ROC, keyword vs semantic refuser (AUC 0.810 vs 0.985); `--fig` prints the Figure 8.4 points | `python3 code/ch08/over_refusal_roc.py [--fig]` |
| `toy_agentdojo.py` | 8.7 `#prompt-injection` | dict bank, user/injection tasks with ground truth and state checks; benign utility, utility under attack, targeted ASR; spotlighting and detector defences; buggy vs fixed security predicate; adaptive injection without the `<INFO>` marker lifts the detector's ASR from 0.018 to 0.265 | `python3 code/ch08/toy_agentdojo.py` |
| `test_toy_agentdojo.py` | 8.7 | unit tests that catch the `service or "" in ...` precedence slip (pytest or plain script) | `python3 code/ch08/test_toy_agentdojo.py` |
| `elicitation_gap.py` | 8.8 `#dangerous-capabilities` | weak vs strong scaffold vs fine-tune elicitation, pass@1 vs pass@10, subtasks; a rule-out decision flips (0.052 vs 0.675); worked pass@k 0.778 and time horizon t50 = 64 min | `python3 code/ch08/elicitation_gap.py` |
| `sycophancy_flip.py` | 8.9 `#alignment` | flip rate vs beneficial flip rate for sycophantic / stubborn / calibrated mocks | `python3 code/ch08/sycophancy_flip.py` |
| `bbq_scorer.py` | 8.10 `#honesty-bias` | BBQ s_DIS and s_AMB (worked 0.16); the more accurate model is the biased one | `python3 code/ch08/bbq_scorer.py` |
| `sandbagging_detection.py` | 8.11 `#eval-integrity` | password-locked sandbagger vs honest-weak model; elicitation gap; IRT person-fit l_z | `python3 code/ch08/sandbagging_detection.py` |
| `eval_awareness_auc.py` | 8.11 `#eval-integrity` | Mann-Whitney AUC of an eval-vs-deploy probe; awareness-conditional behaviour biases the measured rate | `python3 code/ch08/eval_awareness_auc.py` |
| `control_eval.py` | 8.11 `#eval-integrity-control` | trusted monitoring (2% audit) and trusted editing vs a backdoor attack policy: safety/usefulness frontier 0.412/1.000, 0.581/0.931, 0.712/0.846 | `python3 code/ch08/control_eval.py` |
| `threshold_policy.py` | 8.12 `#frameworks`, Fig 8.5 | point vs upper-CI vs upper-CI + elicitation-margin decision rules; wrongful-clearance probability | `python3 code/ch08/threshold_policy.py` |

Every script asserts the numbers quoted in the chapter, so a passing run means the text and the code agree.
