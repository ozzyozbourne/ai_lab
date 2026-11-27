"""Example 30.5 - CPU-friendly baseline: evolution strategies (NumPy) with a linear policy.

Policy: a = clip(w . obs + b, -1, 1), 6 numbers. Each iteration draws P random perturbations
eps_i and evaluates theta + sigma*eps_i and theta - sigma*eps_i, one candidate per world, so
NWORLD = 2P candidates run in ONE batched rollout. Fitness = return of the first episode
(the time limit equals the rollout horizon). Update: rank-normalized antithetic gradient
estimate (Salimans et al. 2017). Runs on CPU in seconds; saves the policy to policy_es.npz,
which Example 30.7 evaluates when no PPO checkpoint exists.
Run: python ex5_es_baseline.py [--iters N] [--dump-json PATH]
"""
import argparse
import json
import pathlib
import sys

import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

HERE = pathlib.Path(__file__).parent if "__file__" in globals() else pathlib.Path.cwd()
sys.path.insert(0, str(HERE))
from ex1_env import CartpoleEnv, OBS_DIM

parser = argparse.ArgumentParser()
parser.add_argument("--iters", type=int, default=None)
parser.add_argument("--dump-json", default=None)
args, _ = parser.parse_known_args()

np.set_printoptions(precision=3, suppress=True)
ON_GPU = wp.get_device().is_cuda
NWORLD = 4096 if ON_GPU else 32           # 2 * population
ITERS = args.iters or (50 if ON_GPU else 30)
HORIZON = 200                             # control steps = 4 s; also the time limit
SIGMA, LR = 0.1, 0.5


def rollout(env, params):
    """Run every world with its own linear policy for HORIZON steps; first-episode returns."""
    w, b = params[:, :OBS_DIM], params[:, OBS_DIM]
    env.reset()
    act = wp.zeros((env.nworld, 1), dtype=float)
    alive = np.ones(env.nworld, dtype=bool)
    ret = np.zeros(env.nworld)
    length = np.zeros(env.nworld, dtype=int)
    for _ in range(HORIZON):
        obs = env.obs_wp.numpy()          # host round trip: fine for a CPU baseline
        act.assign(np.clip((w * obs).sum(1) + b, -1, 1).reshape(-1, 1).astype(np.float32))
        env.step(act)
        ret += alive * env.reward_wp.numpy()
        length += alive
        alive &= ~(env.terminated_wp.numpy() | env.truncated_wp.numpy())
    return ret, length


def ranks(x):
    """Centered ranks in [-0.5, 0.5]: robust to the scale of the returns."""
    r = np.empty(len(x))
    r[np.argsort(x)] = np.arange(len(x))
    return r / (len(x) - 1) - 0.5


env = CartpoleEnv(NWORLD, backend="warp", max_steps=HORIZON, seed=0)
rng = np.random.default_rng(0)
theta = np.zeros(OBS_DIM + 1)
P = NWORLD // 2
history = []
print("device:", wp.get_device(), "| candidates per iteration:", NWORLD, "| params:", theta.size)
for it in range(ITERS):
    eps = rng.standard_normal((P, theta.size))
    cand = np.concatenate([theta + SIGMA * eps, theta - SIGMA * eps])
    env.seed.assign([it])                 # new initial states every iteration
    ret, length = rollout(env, cand)
    f = ranks(ret)
    grad = ((f[:P] - f[P:])[:, None] * eps).sum(0) / (P * SIGMA)
    theta += LR * SIGMA * grad            # step size LR*SIGMA in parameter space
    mean_ret, mean_len = (ret[:P] + ret[P:]).mean() / 2, length.mean()
    history.append([it, round(float(mean_ret), 2), round(float(mean_len), 1)])
    print(f"iter {it:2d}: mean return {mean_ret:7.2f} | mean length {mean_len:5.1f} "
          f"| best {ret.max():7.2f}")

# evaluate the mean policy (no noise) in every world
ret, length = rollout(env, np.tile(theta, (NWORLD, 1)))
print("policy w, b:", theta[:OBS_DIM], round(float(theta[OBS_DIM]), 3))
print(f"final policy: mean return {ret.mean():.2f}, worlds reaching the {HORIZON}-step limit: "
      f"{int((length == HORIZON).sum())}/{NWORLD}")
np.savez("policy_es.npz", w=theta[:OBS_DIM], b=theta[OBS_DIM:])
print("saved policy_es.npz")
if args.dump_json:
    with open(args.dump_json, "w") as f:
        json.dump({"source": "ex5_es_baseline.py", "nworld": NWORLD, "horizon": HORIZON,
                   "history": history}, f, separators=(",", ":"))
    print("wrote", args.dump_json)
