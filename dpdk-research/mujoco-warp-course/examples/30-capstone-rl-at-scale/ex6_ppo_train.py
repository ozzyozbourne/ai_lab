"""Example 30.6 - train the cartpole balance task with the reference PPO (ppo_reference.py).

GPU budget: 4096 worlds x 32 steps x 150 iterations (about 20M env steps; print your own time).
CPU budget: 3 tiny iterations with 16 worlds, enough to check that everything runs end to end.
Prints iteration, mean return of the last finished episodes, mean length and env-steps/s, and
saves the policy to policy_ppo.pt, which Examples 30.7 and 30.8 load.
Run: python ex6_ppo_train.py [--iters N] [--nworld N] [--dump-json PATH]
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

parser = argparse.ArgumentParser()
parser.add_argument("--iters", type=int, default=None)
parser.add_argument("--nworld", type=int, default=None)
parser.add_argument("--dump-json", default=None)
args, _ = parser.parse_known_args()

try:
    import torch
except ImportError:
    torch = None
    print("skipped: torch not installed (PPO needs torch; Example 30.5 trains without it)")

if torch is not None:
    from ex1_env import CartpoleEnv
    from ppo_reference import PPO, PPOConfig

    ON_GPU = wp.get_device().is_cuda
    NWORLD = args.nworld or (4096 if ON_GPU else 16)
    ITERS = args.iters or (150 if ON_GPU else 3)
    env = CartpoleEnv(NWORLD, backend="torch", seed=0)
    agent = PPO(env, PPOConfig(n_steps=32), seed=0)
    print("device:", wp.get_device(), "| torch device:", agent.device, "| nworld:", NWORLD,
          "| iterations:", ITERS)
    print("samples per iteration:", agent.cfg.n_steps * NWORLD,
          "| policy parameters:", sum(p.numel() for p in agent.model.parameters()))
    history = agent.train(ITERS)
    agent.save("policy_ppo.pt")
    print("saved policy_ppo.pt | overflow:",
          "none" if not env.d.overflow.numpy().any() else env.d.overflow.numpy())
    if args.dump_json:
        rows = [[h["iter"], round(h["mean_return"], 2), round(h["mean_length"], 1)]
                for h in history]
        with open(args.dump_json, "w") as f:
            json.dump({"source": "ex6_ppo_train.py", "nworld": NWORLD, "history": rows}, f,
                      separators=(",", ":"))
        print("wrote", args.dump_json)
