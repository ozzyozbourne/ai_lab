"""Example 30.13 (stretch) - swing-up: start hanging down (hinge = pi), energy-shaped reward.

CartpoleEnv(swingup=True) starts every episode at theta = pi + noise, never terminates on the
angle, and rewards 0.5*(1 + cos theta) plus 0.5*exp(-2*|E - E_up|), a bonus for having the
pole energy E of the upright pole (energy shaping), minus small cart-position and effort costs.
A linear policy cannot swing up AND balance, so this ES baseline uses a few nonlinear features:
[obs, theta_dot*cos(theta), sin(theta)*cos(theta)]. Success = the pole is within 20 degrees of upright at the end.
CPU budget: 32 candidates, 25 iterations; GPU: 4096 candidates, 100 iterations.
Run: python ex13_swingup.py
"""
import pathlib
import sys

import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

HERE = pathlib.Path(__file__).parent if "__file__" in globals() else pathlib.Path.cwd()
sys.path.insert(0, str(HERE))
from ex1_env import CartpoleEnv

ON_GPU = wp.get_device().is_cuda
NWORLD = 4096 if ON_GPU else 32
ITERS = 100 if ON_GPU else 25
HORIZON, SIGMA, LR = 300, 0.2, 0.5          # 6 s episodes


def features(o):
    return np.concatenate([o, (o[:, 4] * o[:, 1])[:, None], (o[:, 2] * o[:, 1])[:, None],
                           np.ones((len(o), 1))], 1)


def rollout(env, params):
    env.reset()
    act = wp.zeros((env.nworld, 1), dtype=float)
    ret = np.zeros(env.nworld)
    alive = np.ones(env.nworld, dtype=bool)
    for _ in range(HORIZON):
        o = env.obs_wp.numpy()
        act.assign(np.clip((params * features(o)).sum(1), -1, 1).reshape(-1, 1).astype(np.float32))
        env.step(act)
        ret += alive * env.reward_wp.numpy()
        alive &= ~(env.terminated_wp.numpy() | env.truncated_wp.numpy())
    cos_end = env.final_obs_wp.numpy()[:, 1]       # the state the time limit cut
    return ret, cos_end


env = CartpoleEnv(NWORLD, backend="warp", max_steps=HORIZON, swingup=True, seed=0)
rng = np.random.default_rng(1)
theta = np.zeros(8)
P = NWORLD // 2
print("device:", wp.get_device(), "| candidates:", NWORLD, "| iterations:", ITERS)
for it in range(ITERS):
    eps = rng.standard_normal((P, theta.size))
    env.seed.assign([it])
    ret, _ = rollout(env, np.concatenate([theta + SIGMA * eps, theta - SIGMA * eps]))
    rank = np.empty(NWORLD)
    rank[np.argsort(ret)] = np.arange(NWORLD)
    f = rank / (NWORLD - 1) - 0.5
    theta += LR * SIGMA * ((f[:P] - f[P:])[:, None] * eps).sum(0) / (P * SIGMA)
    if it % 5 == 0 or it == ITERS - 1:
        print(f"iter {it:3d}: mean return {ret.mean():7.1f} | best {ret.max():7.1f}")
env.seed.assign([999])
ret, cos_end = rollout(env, np.tile(theta, (NWORLD, 1)))
up = cos_end > np.cos(np.deg2rad(20))
print(f"final policy: mean return {ret.mean():.1f} | success (within 20 deg of upright at "
      f"{HORIZON * env.dt:.0f} s): {int(up.sum())}/{NWORLD} = {100 * up.mean():.0f}%")
print("a linear-in-features policy is a weak swing-up controller: try PPO (ex6) with swingup=True")
