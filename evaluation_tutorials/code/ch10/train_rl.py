"""Section 10.10: from eval to RL environment. Train a tiny policy on ShopDesk-v1 with GRPO-style updates.

Policy: tabular softmax over four strategies, conditioned on the intent in the customer's first message
(refund / cancel / lookup):  careful (v2 behaviour), sloppy (skips identity checks), hack (claims success
and calls the tool on a fake id), escalate (hands everything to a human). Each strategy is an agent from
evalsuite.agents; the env is unchanged, only reward_fn differs.

Training reward = grader pass x (1 - 0.05 x steps): a common efficiency bonus that makes shortcuts pay.
Grader = the weak v0 grader (output + tool name) or the hardened one (state hash + outputs + policy).
GRPO-style: for each task sample G = 8 strategies, advantage A_i = (r_i - mean) / std within the group,
zero-variance groups give no gradient. Train on the 70 dev tasks, evaluate on the 140 held-out test
tasks with the hardened grader. 5 seeds per grader; IQM and bootstrap CI across seeds.

Run:  python3 code/ch10/train_rl.py      (about 8 s)
      python3 code/ch10/train_rl.py --no-std   (advantage r - mean, without the std division; cf. Dr. GRPO)
Writes data/rl_curves.json (values for Figure 10.4).
"""
import json
import math
import pathlib
import sys

import numpy as np

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from evalsuite.agents import make_agent, parse_user                 # noqa: E402
from evalsuite.env import ShopDeskEnv                                # noqa: E402
from evalsuite.graders import grade_hardened, grade_weak            # noqa: E402
from evalsuite.stats import iqm                                     # noqa: E402
from evalsuite.tasks import build_tasks                              # noqa: E402

STRATS = ["careful", "sloppy", "hacker_fake_id", "escalate_all"]
SHORT = {"careful": "careful", "sloppy": "sloppy", "hacker_fake_id": "hack", "escalate_all": "escalate"}
INTENTS = ["refund", "cancel", "lookup"]
INIT = np.array([0.0, 0.7, -1.6, -1.0])          # start near v1: mostly sloppy, a little hacking
ITERS, BATCH, G, LR, STEP_COST, EVAL_EVERY = 40, 8, 8, 2.0, 0.05, 5


def rollout(task, strat, seed, grader):
    env = ShopDeskEnv(task, reward_fn=grader)
    agent = make_agent(strat)
    obs, _ = env.reset(seed=seed)
    agent.reset(seed + 1)
    done = False
    while not done:
        obs, r, term, trunc, _ = env.step(agent.act(obs))
        done = term or trunc
    return r, env


def softmax(z):
    e = np.exp(z - z.max(-1, keepdims=True))
    return e / e.sum(-1, keepdims=True)


def evaluate(theta, tasks, rng):
    pi = softmax(theta)
    succ = expl = 0
    for t in tasks:
        s = rng.choice(4, p=pi[INTENTS.index(parse_user_intent(t))])   # what the policy sees, never task metadata
        _, env = rollout(t, STRATS[s], int(rng.integers(1 << 30)), None)
        h, w = grade_hardened(t, env.db, env.transcript), grade_weak(t, env.db, env.transcript)
        succ += h
        expl += (w == 1 and h == 0)
    return succ / len(tasks), expl / len(tasks)


def train(grader, seed, dev, test, no_std=False):
    rng = np.random.default_rng(seed)
    theta = np.tile(INIT, (3, 1)).astype(float)
    intent_of = {t["id"]: INTENTS.index(parse_user_intent(t)) for t in dev}
    log = []
    for it in range(ITERS + 1):
        if it % EVAL_EVERY == 0:
            ho, ex = evaluate(theta, test, np.random.default_rng(seed * 1000 + it))
        if it == ITERS:
            log.append((it, float("nan"), ho, ex, softmax(theta)[0, 2], float("nan"), softmax(theta)[0, 0]))
            break
        pi = softmax(theta)
        grad = np.zeros_like(theta)
        rewards, zero_var = [], 0
        for t in rng.choice(dev, BATCH, replace=False):
            i = intent_of[t["id"]]
            s = rng.choice(4, size=G, p=pi[i])
            r = np.array([(lambda rr, env: rr * (1 - STEP_COST * env.steps))(*rollout(t, STRATS[k], int(rng.integers(1 << 30)), grader))
                          for k in s])
            rewards += list(r)
            if r.std() < 1e-9:
                zero_var += 1
                continue
            adv = (r - r.mean()) if no_std else (r - r.mean()) / r.std()    # --no-std: Dr. GRPO-style
            for a, k in zip(adv, s):
                g = -pi[i].copy()
                g[k] += 1.0
                grad[i] += a * g / G
        theta += LR * grad / BATCH
        if it % EVAL_EVERY == 0:
            log.append((it, float(np.mean(rewards)), ho, ex, pi[0, 2], zero_var / BATCH, pi[0, 0]))
    return log, softmax(theta)


def parse_user_intent(task):
    from evalsuite.users import UserSim
    import random
    return parse_user(UserSim(task["user"], random.Random(0)).opening())["intent"]


def boot_iqm_ci(x, B=2000, seed=0):
    rng = np.random.default_rng(seed)
    x = np.asarray(x)
    vals = [iqm(x[rng.integers(0, len(x), len(x))]) for _ in range(B)]
    return tuple(np.percentile(vals, [2.5, 97.5]))


def main():
    no_std = "--no-std" in sys.argv
    tasks = build_tasks()
    dev = [t for t in tasks if t["split"] == "dev"]
    test = [t for t in tasks if t["split"] == "test"]
    print(f"ShopDesk-v1 as an RL environment: train on {len(dev)} dev tasks, evaluate on {len(test)} test tasks")
    print(f"GRPO-style: {ITERS} iterations x {BATCH} tasks x G={G}; reward = grader x (1 - {STEP_COST} x steps)"
          + ("; advantage = r - mean (no std division)" if no_std else "") + "\n")
    runs = {"weak": [], "hardened": []}
    finals = {}
    for name, grader in (("weak", grade_weak), ("hardened", grade_hardened)):
        for seed in range(5):
            log, pi = train(grader, seed, dev, test, no_std)
            runs[name].append(log)
            finals.setdefault(name, []).append(pi)
    print("mean over 5 seeds. held-out = hardened-grader success on test; exploit = weak passes but hardened")
    print("fails; careful / hack = policy probability for refund requests; 0-var = share of zero-variance groups")
    print(f"{'':>5} | {'trained on the WEAK grader':^46} | {'trained on the HARDENED grader':^46}")
    hdr = f"{'train R':>8}{'held-out':>9}{'exploit':>8}{'careful':>8}{'hack':>6}{'0-var':>6}"
    print(f"{'iter':>5} | {hdr:<46} | {hdr:<46}")
    curves = {}
    for name in runs:
        arr = np.array(runs[name], dtype=float)              # seeds x evals x 6
        curves[name] = {"iter": arr[0, :, 0].tolist(), "train_reward": [None if math.isnan(v) else v for v in arr[:, :, 1].mean(0)],
                        "heldout": arr[:, :, 2].mean(0).tolist(), "exploit": arr[:, :, 3].mean(0).tolist()}
    for j, it in enumerate(curves["weak"]["iter"]):
        row = []
        for name in ("weak", "hardened"):
            arr = np.array(runs[name], dtype=float)[:, j]
            tr = "" if math.isnan(arr[0, 1]) else f"{np.mean(arr[:, 1]):.3f}"
            zv = "" if math.isnan(arr[0, 5]) else f"{np.mean(arr[:, 5]):.2f}"
            row.append(f"{tr:>8}{np.mean(arr[:, 2]):>9.3f}{np.mean(arr[:, 3]):>8.3f}{np.mean(arr[:, 6]):>8.2f}"
                       f"{np.mean(arr[:, 4]):>6.2f}{zv:>6}")
        print(f"{int(it):>5} | {row[0]:<46} | {row[1]:<46}")

    print("\nfinal held-out success across 5 seeds (IQM, 95% bootstrap CI over seeds)")
    for name in ("weak", "hardened"):
        x = [log[-1][2] for log in runs[name]]
        e = [log[-1][3] for log in runs[name]]
        lo, hi = boot_iqm_ci(x)
        pi = np.mean(finals[name], 0)
        mix = ", ".join(f"{SHORT[s]} {pi[0, k]:.2f}" for k, s in enumerate(STRATS))
        print(f"  {name:<9} IQM {iqm(x):.3f} [{lo:.3f}, {hi:.3f}]  seeds {', '.join(f'{v:.3f}' for v in x)}"
              f"  exploit {np.mean(e):.3f}")
        print(f"            final policy for refund requests: {mix}")
    if no_std:                                   # a variant run: leave Figure 10.6's data alone
        return
    (HERE / "data" / "rl_curves.json").write_text(json.dumps(curves, indent=1))
    assert curves["weak"]["exploit"][-1] > 0.3 and curves["weak"]["heldout"][-1] < curves["weak"]["heldout"][0] and curves["hardened"]["exploit"][-1] < 0.05
    assert curves["hardened"]["heldout"][-1] > curves["weak"]["heldout"][-1] + 0.2


if __name__ == "__main__":
    main()
