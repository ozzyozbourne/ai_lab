"""Example 30.11 - contact track, step 3: train HumanoidStandEnv with the reference PPO.

GPU budget: 2048 worlds x 32 steps x 300 iterations (about 20M env steps, 80M physics steps;
print your own time, about 20-30 min on a Colab GPU is the target). CPU budget: 2 tiny iterations
with 8 worlds, to check the pipeline end to end. After every iteration it prints the mean
episode length and return of the last finished episodes and the overflow bits seen during the
rollout (decoded from env.overflow_seen, which survives auto-resets), plus the contact budget of
that rollout from env.contact_stats(): worst nacon against naconmax, worst nefc against njmax and
the mean solver_niter. Saves policy_humanoid.pt.
Run: python ex11_humanoid_train.py [--iters N] [--nworld N]
"""
import argparse
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
args, _ = parser.parse_known_args()

try:
    import torch
except ImportError:
    torch = None
    print("skipped: torch not installed (PPO needs torch)")

if torch is not None:
    from ex10_humanoid_env import HumanoidStandEnv
    from ppo_reference import PPO, PPOConfig

    ON_GPU = wp.get_device().is_cuda
    NWORLD = args.nworld or (2048 if ON_GPU else 8)
    ITERS = args.iters or (300 if ON_GPU else 2)
    env = HumanoidStandEnv(NWORLD, backend="torch", seed=0)
    agent = PPO(env, PPOConfig(n_steps=32, hidden=(128, 128), lr=3e-4), seed=0)
    print("device:", wp.get_device(), "| nworld:", NWORLD, "| iterations:", ITERS,
          f"| obs {agent.obs_dim}, actions {agent.act_dim}")
    for it in range(ITERS):
        h = agent.train(1, log=None)[0]
        ov = env.overflow()                      # bits raised during this rollout, then cleared
        cs = env.contact_stats()                 # worst nacon / nefc, mean niter, then cleared
        print(f"iter {it:3d} | mean length {h['mean_length']:6.1f} | mean return "
              f"{h['mean_return']:8.2f} | {h['steps_per_s']:8.0f} env-steps/s | {cs['text']} | "
              "overflow: " + ov.replace("\n", "; "))
    agent.save("policy_humanoid.pt")
    print("saved policy_humanoid.pt")
