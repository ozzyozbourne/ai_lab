"""Example 5.11 - record a GIF: mjwarp-record on a GPU, the same loop by hand on CPU.

mjwarp-record is GPU only in 4.0.1: cli.unroll calls wp.get_stream() for every step, which raises
"Device cpu is not a CUDA device" on CPU. So on a GPU we call the CLI (RGB, then depth, with the
batch renderer: --render_mode warp), and on CPU we run the loop record.py runs ourselves:
step -> refit_bvh -> render -> get_rgb, every render_every steps, then save with PIL.
Run: python ex11_record.py [--nstep N] [--dump-png DIR]
  --dump-png DIR  writes 3 of the recorded frames (first, middle, last) for the page.
"""
import argparse
import importlib.util
import os
import shutil
import struct
import subprocess
import zlib

import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw
from etils import epath

def save_png(path, img):
    """Write an (H, W, 3) uint8 array as an 8-bit RGB PNG (standard library only)."""
    h, w, _ = img.shape
    raw = b"".join(b"\x00" + img[y].tobytes() for y in range(h))   # filter type 0 per row

    def chunk(tag, data):
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data))

    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
                + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))


parser = argparse.ArgumentParser()
parser.add_argument("--nstep", type=int, default=100)
parser.add_argument("--dump-png", default=None)
args, _ = parser.parse_known_args()

ON_GPU = wp.get_device().is_cuda
HUMANOID = str(epath.resource_path("mujoco_warp") / "test_data/humanoid/humanoid.xml")
HAS_CLI = shutil.which("mjwarp-record") is not None
HAS_PIL = importlib.util.find_spec("PIL") is not None

if ON_GPU and HAS_CLI and HAS_PIL:
    base = ["mjwarp-record", HUMANOID, "--nworld", "1", "--nstep", str(args.nstep),
            "--render_mode", "warp"]
    subprocess.run(base + ["--output", "humanoid.gif"], check=True)
    subprocess.run(base + ["--channel", "depth", "--output", "depth.gif"], check=True)
    print("wrote humanoid.gif and depth.gif")
else:
    print(f"skipped mjwarp-record (GPU: {ON_GPU}, CLI on PATH: {HAS_CLI}, PIL: {HAS_PIL});"
          " running the same loop by hand")
    mjm = mujoco.MjModel.from_xml_path(HUMANOID)
    m = mjw.put_model(mjm)
    d = mjw.make_data(mjm, nworld=1, nconmax=32, njmax=128)
    rc = mjw.create_render_context(mjm, nworld=1, cam_res=(64, 64), render_rgb=True,
                                   render_depth=False, render_seg=False)
    rgb = wp.zeros((1, 64, 64), dtype=wp.vec3)
    render_every = max(1, int(1.0 / (30 * mjm.opt.timestep)))     # record.py's rule, 30 fps
    frames = []
    for step in range(args.nstep):
        mjw.step(m, d)
        if step % render_every == 0:
            mjw.refit_bvh(m, d, rc)
            mjw.render(m, d, rc)
            mjw.get_rgb(rc, 0, rgb)                                  # camera index 0
            frames.append((np.clip(rgb.numpy()[0], 0, 1) * 255).astype(np.uint8))
    print(f"ncam {mjm.ncam} | dt {mjm.opt.timestep} | render every {render_every} steps ->"
          f" {len(frames)} frames, each {frames[0].shape}")
    bits = int(d.overflow.numpy()[0])
    print("overflow:", [o.name for o in mjw.OverflowType if bits & o] or "none")
    if HAS_PIL:
        from PIL import Image
        ims = [Image.fromarray(f) for f in frames]
        ims[0].save("out.gif", save_all=True, append_images=ims[1:],
                    duration=int(render_every * mjm.opt.timestep * 1000), loop=0)
        print("saved out.gif")
    else:
        print("skipped: PIL not installed (pip install pillow) - no GIF written")
    if args.dump_png:
        os.makedirs(args.dump_png, exist_ok=True)
        for k in (0, len(frames) // 2, len(frames) - 1):
            save_png(os.path.join(args.dump_png, f"ex11_frame{k:02d}.png"), frames[k])
        print("wrote 3 PNGs to", args.dump_png)
