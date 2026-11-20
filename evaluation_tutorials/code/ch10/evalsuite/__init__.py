"""evalsuite: the Chapter 10 capstone package (ShopDesk eval suite + RL environment).

Modules
    env      ShopDeskEnv, a Gymnasium-style environment (reset/step 5-tuple), tool backend, state hash
    tasks    task generator: templates x slices, splits, canary, content hashes
    users    scripted user simulator with persona variants
    agents   mock agents: null, random, gold, v1, v2, hacker, leak exploiter, strategy agents for RL
    graders  AST tool-call checker, state-hash + required-output grader, policy checker, weak grader,
             trace grader, mock LLM tone judge
    stats    Wilson, clustered SE, paired bootstrap, McNemar, pass@k, pass^k, MDE, kappa, IQM, PPI, PSI
    card     results-card criteria, bootstrap and cluster-Wilson CIs, verdicts
    qa       environment QA: gold, null, determinism, leakage, isolation
    runner   trials with a fresh env per trial, infra_error status + retry, cost/latency, span logs

Everything is offline and seeded: same seed, same output.
"""
ENV_ID = "ShopDesk-v1"
