"""Example 30.4 - episodes end and restart per world; truncation is flagged apart from termination.

A noisy linear controller (gains from an LQR design, scaled differently per world) runs 16
worlds for 300 control steps with a 100-step time limit. Strong controllers survive to the time
limit (TRUNCATED: the episode was cut, the pole did not fall); weak ones let the pole fall
(TERMINATED). Every world restarts on its own schedule (asynchronous episodes).
Run: python ex4_episodes.py [--dump-json PATH]
  --dump-json PATH writes the per-world episode segments for the page's episode timeline.
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
from ex1_env import CartpoleEnv

parser = argparse.ArgumentParser()
parser.add_argument("--dump-json", default=None)
args, _ = parser.parse_known_args()

NWORLD, NSTEP, MAX_STEPS = 16, 300, 100
K = np.array([0.9, 6.8, 1.1, 1.2])          # LQR-like gains on (x, theta, x_dot, theta_dot)
scale = np.linspace(0.0, 1.0, NWORLD)       # world k uses scale[k] * K (world 0: no control)

env = CartpoleEnv(NWORLD, backend="warp", max_steps=MAX_STEPS, seed=3)
env.reset()
rng = np.random.default_rng(0)
act = wp.zeros((NWORLD, 1), dtype=float)
events = []                                 # (step, world, "T" | "R")
for i in range(NSTEP):
    # this demo reads obs on the host every step to log events; a training loop never does
    o = env.obs_wp.numpy()
    th = np.arctan2(o[:, 2], o[:, 1])
    a = scale * (np.stack([o[:, 0], th, o[:, 3], o[:, 4]], 1) @ K) + rng.normal(0, 0.3, NWORLD)
    act.assign(a.reshape(NWORLD, 1).astype(np.float32))
    env.step(act)
    term, trunc = env.terminated_wp.numpy(), env.truncated_wp.numpy()
    assert not (term & trunc).any(), "a step is either terminated or truncated, never both"
    for w in np.nonzero(term)[0]:
        events.append((i + 1, int(w), "T"))
    for w in np.nonzero(trunc)[0]:
        events.append((i + 1, int(w), "R"))

lengths = {"T": [], "R": []}
segments = [[] for _ in range(NWORLD)]
last = np.zeros(NWORLD, dtype=int)
for step, w, kind in events:
    lengths[kind].append(step - last[w])
    segments[w].append([int(last[w]), int(step), kind])
    last[w] = step
for w in range(NWORLD):
    if last[w] < NSTEP:
        segments[w].append([int(last[w]), NSTEP, "open"])
print("device:", wp.get_device(), "| nworld:", NWORLD, "| control steps:", NSTEP,
      "| time limit:", MAX_STEPS)
print(f"terminated episodes: {len(lengths['T'])} | truncated episodes: {len(lengths['R'])}")
print("episodes per world:", [len([s for s in seg if s[2] != 'open']) for seg in segments])
bins = [0, 20, 40, 60, 80, 100, 101]                 # last bin = exactly 100 steps
cT, edges = np.histogram(lengths["T"], bins=bins)   # separate counts: a TERMINATED episode
cR, _ = np.histogram(lengths["R"], bins=bins)       # can also last exactly 100 steps
print("  episode lengths (#: terminated, =: truncated)")
for lo, hi, t, r in zip(edges[:-1], edges[1:], cT, cR):
    label = f"{lo:3d}-{hi - 1:3d}" if hi - lo > 1 else f"{lo:3d}    "
    print(f"  length {label}: {'#' * t}{'=' * r} {t} terminated, {r} truncated")
print("lengths of truncated episodes:", sorted({int(n) for n in lengths["R"]}), "(the time limit)")
st = env.episode_stats()
print(f"device-side stats agree: {st['episodes']} episodes finished "
      f"(host log: {len(events)})")

if args.dump_json:
    with open(args.dump_json, "w") as f:
        json.dump({"nworld": NWORLD, "nstep": NSTEP, "max_steps": MAX_STEPS, "dt": env.dt,
                   "labels": [f"k={s:.2f}" for s in scale], "segments": segments}, f,
                  separators=(",", ":"))
    print("wrote", args.dump_json)
