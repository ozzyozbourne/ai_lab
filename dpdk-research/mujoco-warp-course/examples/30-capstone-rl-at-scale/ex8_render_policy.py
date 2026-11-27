"""Example 30.8 - render the trained policy: world 0 as frames and a 4x4 batch-render grid.

16 worlds with 16 different pole masses (eager mass DR + set_const) run the PPO policy if
policy_ppo.pt exists (and torch is installed), else the ES policy. mujoco.Renderer (C MuJoCo,
OpenGL) renders world 0 when an OpenGL backend exists; otherwise the MJWarp batch renderer
renders ALL worlds in one launch (works on Warp's CPU device), which also gives the 4x4 grid.
Run: python ex8_render_policy.py [--policy ppo|es] [--dump-json PATH] [--dump-png DIR]
  --dump-json PATH  decimated (cart x, pole angle) per world for the page's replay player
  --dump-png DIR    ex8_grid.png (4x4 batch render, last frame) and ex8_world0.png (a strip)
"""
import argparse
import json
import os
import pathlib
import struct
import sys
import zlib

import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

HERE = pathlib.Path(__file__).parent if "__file__" in globals() else pathlib.Path.cwd()
sys.path.insert(0, str(HERE))
from ex1_env import CartpoleEnv, my_env

parser = argparse.ArgumentParser()
parser.add_argument("--dump-json", default=None)
parser.add_argument("--dump-png", default=None)
parser.add_argument("--policy", choices=["ppo", "es"], default=None)
args, _ = parser.parse_known_args()

try:
    import torch
except ImportError:
    torch = None

ON_GPU = wp.get_device().is_cuda
NWORLD, HORIZON, EVERY = 16, 200, 4
W, H = (128, 128) if ON_GPU else (64, 64)


def save_png(path, img):
    """Write an (H, W, 3) uint8 array as an RGB PNG (standard library only)."""
    h, w, _ = img.shape
    raw = b"".join(b"\x00" + img[y].tobytes() for y in range(h))

    def chunk(tag, data):
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data))

    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
                + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))


use_ppo = args.policy != "es" and torch is not None and os.path.exists("policy_ppo.pt")
env = CartpoleEnv(NWORLD, backend="torch" if use_ppo else "warp", max_steps=HORIZON, seed=21)
if use_ppo:
    from ppo_reference import load_policy
    model = load_policy("policy_ppo.pt", device=str(env.obs.device))
    policy = lambda obs: model.act(obs)
    print("policy: PPO checkpoint policy_ppo.pt")
else:
    p = np.load("policy_es.npz")
    w, b = p["w"], float(p["b"][0])
    act = wp.zeros((NWORLD, 1), dtype=float)

    def policy(obs):
        act.assign(np.clip(obs.numpy() @ w + b, -1, 1).reshape(-1, 1).astype(np.float32))
        return act
    print("policy: ES linear policy policy_es.npz")

scale = np.geomspace(0.5, 32.0, NWORLD)                   # one pole mass per world
pole = mujoco.mj_name2id(env.mjm, mujoco.mjtObj.mjOBJ_BODY, "pole")
my_env.scale_body_mass(env.mjm, env.m, env.d, pole, scale)

# renderer: C MuJoCo for world 0 if OpenGL works, else the MJWarp batch renderer for all worlds
renderer, rc = None, None
try:
    renderer = mujoco.Renderer(env.mjm, H, W)
    mjd = mujoco.MjData(env.mjm)
    print("renderer: mujoco.Renderer (OpenGL)")
except Exception as e:
    print(f"mujoco.Renderer unavailable ({type(e).__name__}); using the MJWarp batch renderer")
rc = mjw.create_render_context(env.mjm, nworld=NWORLD, cam_res=(W, H), render_rgb=True)
rgb = wp.zeros((NWORLD, H, W), dtype=wp.vec3)


def render_batch():
    mjw.forward(env.m, env.d)       # poses for the current qpos (reset worlds included)
    mjw.refit_bvh(env.m, env.d, rc)
    mjw.render(env.m, env.d, rc)
    mjw.get_rgb(rc, 0, rgb)
    return (np.clip(rgb.numpy(), 0, 1) * 255).astype(np.uint8)


obs = env.reset()
frames, video, alive = [], [], np.ones(NWORLD, dtype=bool)
for i in range(HORIZON):
    obs, rew, term, trunc = env.step(policy(obs))
    alive &= ~(term.cpu().numpy() if use_ppo else term.numpy())
    if i % EVERY == 0:
        q = env.d.qpos.numpy()
        frames.append([[round(float(x), 3), round(float(t), 3)] for x, t in q])
        if renderer is not None:
            mjw.get_data_into(mjd, env.mjm, env.d, world_id=0)
            renderer.update_scene(mjd, camera="front")
            video.append(renderer.render())
        elif i % (4 * EVERY) == 0:
            video.append(render_batch()[0])
grid = render_batch()
print("device:", wp.get_device(), f"| {NWORLD} worlds | {HORIZON} steps | frames kept "
      f"{len(frames)} | video frames {len(video)} of {video[0].shape}")
print("still balancing at the end:", int(alive.sum()), "/", NWORLD,
      "| pole mass factor of the failures:", np.round(scale[~alive], 2).tolist())
print("batch render:", grid.shape, grid.dtype, "| mean RGB world 0:",
      grid[0].reshape(-1, 3).mean(0).round(1))
try:
    import mediapy as media
    media.write_video("ex8_world0.mp4", video, fps=1 / (EVERY * env.dt))
    print("wrote ex8_world0.mp4")
except ImportError:
    print("skipped: mediapy not installed (no video file)")

if args.dump_json:
    with open(args.dump_json, "w") as f:
        json.dump({"nworld": NWORLD, "dt": EVERY * env.dt, "kind": "cartpole",
                   "labels": [f"m x{s:.2f}" for s in scale], "alive": alive.tolist(),
                   "frames": frames}, f, separators=(",", ":"))
    print("wrote", args.dump_json, len(frames), "frames")
if args.dump_png:
    os.makedirs(args.dump_png, exist_ok=True)
    tiles = grid.reshape(4, 4, H, W, 3).transpose(0, 2, 1, 3, 4).reshape(4 * H, 4 * W, 3)
    save_png(os.path.join(args.dump_png, "ex8_grid.png"), tiles)
    strip = np.concatenate(video[:8], axis=1)
    save_png(os.path.join(args.dump_png, "ex8_world0.png"), strip)
    print("wrote", tiles.shape, "grid and", strip.shape, "strip to", args.dump_png)
