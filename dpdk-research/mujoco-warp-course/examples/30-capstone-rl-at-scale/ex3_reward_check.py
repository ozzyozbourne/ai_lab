"""Example 30.3 - test the reward / termination / observation kernels against NumPy.

Writes random states (some far outside the safe set, one NaN) into d.qpos / d.qvel / d.ctrl,
launches the env's _reward_done and _observe kernels directly, and compares every output with a
NumPy reference written from the task definition. Do this for every kernel you write: a sign
error in a reward trains a policy that is perfect at the wrong task.
Run: python ex3_reward_check.py
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
import ex1_env
from ex1_env import CartpoleEnv

NWORLD = 64
X_LIMIT, TH_LIMIT, MAX_STEPS = 1.7, 0.8, 200


def reference(qpos, qvel, ctrl, t, swingup):
    """The task, written once more in NumPy (float64)."""
    x, th, xd, thd, a = qpos[:, 0], qpos[:, 1], qvel[:, 0], qvel[:, 1], ctrl[:, 0]
    bad = ~(np.isfinite(qpos).all(1) & np.isfinite(qvel).all(1))
    c = np.cos(th)
    term = bad | (np.abs(x) > X_LIMIT)
    if not swingup:
        term |= c < np.cos(TH_LIMIT)
        r = c - 0.25 * x**2 - 0.01 * a**2
    else:
        e = (0.5 * 0.012 * thd**2 + 0.2943 * c) / 0.2943
        r = 0.5 * (1 + c) + 0.5 * np.exp(-2 * np.abs(e - 1)) - 0.05 * x**2 - 0.01 * a**2
    r = np.where(bad, 0.0, r)
    trunc = ~term & (t + 1 >= MAX_STEPS)
    obs = np.stack([x, c, np.sin(th), xd, thd], 1)
    return r, term, trunc, obs


rng = np.random.default_rng(0)
print("device:", wp.get_device(), "| random states:", NWORLD)
for swingup in (False, True):
    env = CartpoleEnv(NWORLD, backend="warp", swingup=swingup, use_graph=False)
    qpos = np.stack([rng.uniform(-2.0, 2.0, NWORLD), rng.uniform(-np.pi, np.pi, NWORLD)], 1)
    qvel = rng.normal(0.0, 2.0, (NWORLD, 2))
    ctrl = rng.uniform(-1, 1, (NWORLD, 1))
    qpos[3, 1] = np.nan                                  # one broken world
    t = rng.integers(0, MAX_STEPS, NWORLD)
    t[:4] = MAX_STEPS - 1                                # a few worlds hit the time limit
    env.d.qpos.assign(qpos.astype(np.float32))
    env.d.qvel.assign(qvel.astype(np.float32))
    env.d.ctrl.assign(ctrl.astype(np.float32))
    env.t.assign(t.astype(np.int32))
    wp.launch(ex1_env._reward_done, dim=NWORLD,
              inputs=[env.d.qpos, env.d.qvel, env.d.ctrl, int(swingup), MAX_STEPS, X_LIMIT,
                      float(np.cos(TH_LIMIT)), env.t],
              outputs=[env.reward_wp, env.terminated_wp, env.truncated_wp, env.done,
                       env.final_obs_wp])
    env._observe(env.done)
    # float32 inputs, as the kernels see them
    r, term, trunc, obs = reference(qpos.astype(np.float32).astype(np.float64),
                                    qvel.astype(np.float32).astype(np.float64),
                                    ctrl.astype(np.float32).astype(np.float64), t, swingup)
    ok = np.isfinite(obs).all(1)
    name = "swing-up" if swingup else "balance "
    print(f"{name}: max |reward diff| = {np.abs(env.reward_wp.numpy() - r).max():.2e} | "
          f"max |obs diff| = {np.abs(env.obs_wp.numpy()[ok] - obs[ok]).max():.2e}")
    print(f"          terminated match: {bool((env.terminated_wp.numpy() == term).all())} "
          f"({int(term.sum())} worlds) | truncated match: "
          f"{bool((env.truncated_wp.numpy() == trunc).all())} ({int(trunc.sum())} worlds)")
    print(f"          NaN world 3: terminated={bool(env.terminated_wp.numpy()[3])}, "
          f"reward={env.reward_wp.numpy()[3]:.1f}, final_obs zeroed="
          f"{bool((env.final_obs_wp.numpy()[3] == 0).all())}")
