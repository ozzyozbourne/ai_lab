"""Example 30.7 - evaluate the trained policy under randomized pole masses.

Loads policy_ppo.pt (Example 30.6) if it exists and torch is installed, else policy_es.npz
(Example 30.5), and prints which one it used. Mass is a field WITH derived quantities
(body_subtreemass, dof_invweight0, ...), so the pole mass is randomized EAGERLY between
evaluation rollouts with my_env.scale_body_mass (assign + mjw.set_const), never inside the
captured graph. Motor gain and slider damping stay randomized per episode inside the graph.
A rollout succeeds when the pole is still up at the 200-step (4 s) time limit.
Run: python ex7_evaluate.py [--policy ppo|es]
"""
import argparse
import os
import pathlib
import sys

import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

HERE = pathlib.Path(__file__).parent if "__file__" in globals() else pathlib.Path.cwd()
sys.path.insert(0, str(HERE))
from ex1_env import CartpoleEnv, my_env

parser = argparse.ArgumentParser()
parser.add_argument("--policy", choices=["ppo", "es"], default=None)
args, _ = parser.parse_known_args()

try:
    import torch
except ImportError:
    torch = None

ON_GPU = wp.get_device().is_cuda
SCALES = np.array([0.5, 2.0, 8.0, 16.0, 32.0])     # pole mass / nominal (0.1 kg)
PER_BIN = 256 if ON_GPU else 8
NWORLD = len(SCALES) * PER_BIN
ROLLOUTS, HORIZON = 2, 200

use_ppo = (args.policy != "es" and torch is not None and os.path.exists("policy_ppo.pt"))
if args.policy == "ppo" and not use_ppo:
    print("policy_ppo.pt or torch missing: falling back to the ES policy")
env = CartpoleEnv(NWORLD, backend="torch" if use_ppo else "warp", max_steps=HORIZON, seed=10)
if use_ppo:
    from ppo_reference import load_policy
    model = load_policy("policy_ppo.pt", device=str(env.obs.device))
    policy = lambda obs: model.act(obs)                       # torch in, torch out
    print("policy: PPO checkpoint policy_ppo.pt")
else:
    p = np.load("policy_es.npz")
    w, b = p["w"], float(p["b"][0])
    act = wp.zeros((NWORLD, 1), dtype=float)

    def policy(obs):
        act.assign(np.clip(obs.numpy() @ w + b, -1, 1).reshape(-1, 1).astype(np.float32))
        return act
    print("policy: ES linear policy policy_es.npz")

pole = mujoco.mj_name2id(env.mjm, mujoco.mjtObj.mjOBJ_BODY, "pole")
cart = mujoco.mj_name2id(env.mjm, mujoco.mjtObj.mjOBJ_BODY, "cart")
rng = np.random.default_rng(0)
success = np.zeros(len(SCALES))
print("device:", wp.get_device(), "| worlds:", NWORLD, f"({PER_BIN} per mass bin) | rollouts:",
      ROLLOUTS)
for k in range(ROLLOUTS):
    scale = np.repeat(SCALES, PER_BIN) * rng.uniform(0.9, 1.1, NWORLD)   # jitter inside a bin
    my_env.scale_body_mass(env.mjm, env.m, env.d, pole, scale)   # eager DR + set_const
    sub = env.m.body_subtreemass.numpy()[:, cart]
    print(f"rollout {k}: cart subtree mass (cart + pole) min {sub.min():.3f} max {sub.max():.3f}")
    env.seed.assign([100 + k])
    obs = env.reset()
    alive = np.ones(NWORLD, dtype=bool)
    for _ in range(HORIZON):
        obs, rew, term, trunc = env.step(policy(obs))
        t_np = term.cpu().numpy() if use_ppo else term.numpy()
        alive &= ~t_np
    success += alive.reshape(len(SCALES), PER_BIN).mean(1) / ROLLOUTS
for s, rate in zip(SCALES, success):
    print(f"  pole mass x{s:4.1f} ({0.1 * s:4.2f} kg): success {100 * rate:5.1f}% "
          + "#" * int(round(20 * rate)))
print("overflow:", my_env.describe_overflow(env.d))
