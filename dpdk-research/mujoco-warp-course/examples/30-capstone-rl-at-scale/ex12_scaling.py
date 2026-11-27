"""Example 30.12 (stretch) - scaling study: more worlds per update under a fixed wall-clock budget.

Evolution strategies on the balance task, but now the WHOLE rollout stays on the device: the
linear policy of every candidate is a Warp kernel that reads env.obs_wp and writes env.action,
and a second kernel adds the reward of each world's first episode. The host only touches the
data once per iteration (to rank the candidates). For each nworld we run ES for the same
wall-clock budget and report env-steps/s and the return reached. Bigger populations give
better gradient estimates per iteration; on a GPU they also cost almost nothing extra.
CPU numbers are from Warp's CPU device ("on a CPU dev box"), NOT GPU performance.
Run: python ex12_scaling.py [--budget SECONDS]
"""
import argparse
import pathlib
import sys
import time

import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

HERE = pathlib.Path(__file__).parent if "__file__" in globals() else pathlib.Path.cwd()
sys.path.insert(0, str(HERE))
from ex1_env import CartpoleEnv, OBS_DIM

parser = argparse.ArgumentParser()
parser.add_argument("--budget", type=float, default=None)
args, _ = parser.parse_known_args()

ON_GPU = wp.get_device().is_cuda
SIZES = [256, 1024, 4096, 16384] if ON_GPU else [16, 64, 256]
BUDGET = args.budget or (60.0 if ON_GPU else 4.0)        # seconds per nworld
HORIZON, SIGMA, LR = 200, 0.1, 0.5


@wp.kernel
def linear_policy(obs: wp.array2d(dtype=float), params: wp.array2d(dtype=float),
                  action: wp.array2d(dtype=float)):
    worldid = wp.tid()
    a = params[worldid, 5]                              # bias
    for i in range(5):
        a += params[worldid, i] * obs[worldid, i]
    action[worldid, 0] = wp.clamp(a, -1.0, 1.0)


@wp.kernel
def first_episode(reward: wp.array(dtype=float), done: wp.array(dtype=bool),
                  alive: wp.array(dtype=bool), ret: wp.array(dtype=float)):
    worldid = wp.tid()
    if alive[worldid]:
        ret[worldid] = ret[worldid] + reward[worldid]
        if done[worldid]:
            alive[worldid] = False


def es_run(nworld, budget):
    env = CartpoleEnv(nworld, backend="warp", max_steps=HORIZON, seed=0)
    env.reset()
    params = wp.zeros((nworld, OBS_DIM + 1), dtype=float)
    alive = wp.zeros(nworld, dtype=bool)
    ret = wp.zeros(nworld, dtype=float)
    rng = np.random.default_rng(0)
    theta, P, it, steps = np.zeros(OBS_DIM + 1), nworld // 2, 0, 0
    best = []
    t0 = time.perf_counter()
    while it == 0 or time.perf_counter() - t0 < budget:
        eps = rng.standard_normal((P, theta.size))
        params.assign(np.concatenate([theta + SIGMA * eps, theta - SIGMA * eps]).astype(np.float32))
        env.seed.assign([it])
        env.reset()
        alive.fill_(True)
        ret.zero_()
        for _ in range(HORIZON):                        # no host sync inside this loop
            wp.launch(linear_policy, dim=nworld, inputs=[env.obs_wp, params], outputs=[env.action])
            wp.capture_launch(env.graph)
            wp.launch(first_episode, dim=nworld, inputs=[env.reward_wp, env.done],
                      outputs=[alive, ret])
        r = ret.numpy()                                 # ONE sync per iteration
        rank = np.empty(nworld)
        rank[np.argsort(r)] = np.arange(nworld)
        f = rank / (nworld - 1) - 0.5
        theta += LR * ((f[:P] - f[P:])[:, None] * eps).sum(0) / P
        best.append(float(r.mean()))
        it += 1
        steps += nworld * HORIZON
    sec = time.perf_counter() - t0
    return steps / sec, it, best[-1]


print("device:", wp.get_device(), f"| budget {BUDGET:.0f} s per row | horizon {HORIZON}")
print(f"{'nworld':>7s} {'env-steps/s':>12s} {'iterations':>10s} {'mean return (last iter)':>24s}")
for n in SIZES:
    es_run(n, 0.0)                                      # warm-up: compile + capture outside
    sps, iters, last = es_run(n, BUDGET)
    print(f"{n:7d} {sps:12.0f} {iters:10d} {last:24.1f}")
print("the maximum return is about 200 (1 per step for 200 steps)")
