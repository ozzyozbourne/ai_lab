"""Example 30.2 - random actions; env steps/s with eager launches vs one graph replay per step.

Both envs run the same device code (Example 30.1); only the dispatch differs: eager issues every
kernel launch from Python on every step, the graph replays the recorded launches with one call.
The random actions are drawn on the device (torch) and written into the env's action buffer.
Timing: warm up, then wp.synchronize() before reading the clock. On CPU these are numbers from
Warp's CPU device ("on a CPU dev box"), NOT GPU performance; on a GPU print your own numbers.
Run: python ex2_random_policy.py
"""
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
from ex1_env import CartpoleEnv

ON_GPU = wp.get_device().is_cuda
NWORLD = 4096 if ON_GPU else 8
NSTEP = 1000 if ON_GPU else 50

try:
    import torch
    BACKEND = "torch"
except ImportError:
    torch = None
    BACKEND = "warp"
    print("skipped: torch not installed, using backend='warp' with NumPy actions")

rng = np.random.default_rng(0)
print("device:", wp.get_device(), "| nworld:", NWORLD, "| env steps:", NSTEP, "| backend:", BACKEND)
for use_graph in (False, True):
    env = CartpoleEnv(NWORLD, backend=BACKEND, seed=1, use_graph=use_graph)
    env.reset()
    if torch is not None:
        gen = torch.Generator(device=env.obs.device).manual_seed(0)
        actions = [torch.rand(NWORLD, 1, generator=gen, device=env.obs.device) * 2 - 1
                   for _ in range(NSTEP)]
    else:
        actions = [wp.array(rng.uniform(-1, 1, (NWORLD, 1)).astype(np.float32))
                   for _ in range(NSTEP)]
    env.step(actions[0])                     # warm-up (eager path compiles here)
    wp.synchronize()
    t0 = time.perf_counter()
    for a in actions:
        env.step(a)
    wp.synchronize()
    sec = time.perf_counter() - t0
    st = env.episode_stats()
    mode = "graph" if use_graph else "eager"
    print(f"{mode:5s}: {NSTEP * NWORLD / sec:10.0f} env-steps/s "
          f"({NSTEP * NWORLD * env.n_substeps / sec:10.0f} physics world-steps/s) | "
          f"episodes finished {st['episodes']:3d}, mean length {st['mean_length']:.1f}")
print(f"a random policy keeps the pole up for only {st['mean_length'] * env.dt:.2f} s on average "
      f"(the time limit is {env.max_steps * env.dt:.0f} s)")
