"""Example 27.11 - a rendered rollout: physics graph + render graph (GPU), eager on CPU.

On a GPU we warm up once (JIT + megakernel build), then capture two CUDA graphs: one for
NSUB physics steps and one for refit_bvh + render. Each video frame replays both and unpacks
world 0. On CPU there are no CUDA graphs, so the same calls run eagerly with a tiny budget.
The frames/s table is for THIS device (CPU numbers on a CPU box are not GPU numbers).
Run: python ex11_video_graph.py [--dump-png DIR] [--gif PATH]
  --dump-png DIR  writes ex11_filmstrip.png (world 0, every frame side by side).
  --gif PATH      writes an animated GIF of world 0 (needs Pillow; skipped otherwise).
"""
import argparse
import os
import struct
import time
import zlib

import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

RENDER_SCENE = """
<mujoco model="render_scene">
  <option timestep="0.01666"/>
  <worldbody>
    <light name="top" pos="0 0 2" dir="0 0 -1" directional="true"/>
    <camera name="camera" pos="0 2 0" quat="0 0 1 1" resolution="128 128"/>
    <geom name="floor" type="plane" pos="0 0 -.5" size="2 2 .1" rgba=".9 .9 .9 1"/>
    <body name="box_and_sphere" euler="0 0 -30">
      <joint name="swing" type="hinge" axis="1 -1 0" pos="-.2 -.2 -.2"/>
      <geom name="red_box" type="box" size=".2 .2 .2" rgba="1 0 0 1"/>
      <geom name="green_sphere" pos="-.2 -.2 -.2" size=".1" rgba="0 1 0 1"/>
    </body>
  </worldbody>
</mujoco>
"""


def save_png(path, img):
    """Write an (H, W, 3) uint8 array as an RGB PNG (standard library only)."""
    h, w, _ = img.shape
    raw = b"".join(b"\x00" + img[y].tobytes() for y in range(h))

    def chunk(tag, data):
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data))

    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
                + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))


parser = argparse.ArgumentParser()
parser.add_argument("--dump-png", default=None)
parser.add_argument("--gif", default=None)
args, _ = parser.parse_known_args()

ON_GPU = wp.get_device().is_cuda
NWORLDS = [64, 1024, 8192] if ON_GPU else [1, 4]
W, H = (64, 64) if ON_GPU else (32, 32)
NFRAME = 60 if ON_GPU else 8
NSUB = 2                                        # physics steps per video frame

mjm = mujoco.MjModel.from_xml_string(RENDER_SCENE)


def rollout(nworld, keep_frames):
    m = mjw.put_model(mjm)
    if ON_GPU and not wp.is_conditional_graph_supported():
        m.opt.graph_conditional = False            # CUDA < 12.4: no conditional nodes
        print("note: conditional graphs unsupported, graph_conditional = False")
    d = mjw.make_data(mjm, nworld=nworld)
    qpos = np.tile(mjm.qpos0, (nworld, 1))
    qpos[:, 0] = np.linspace(0.3, 1.5, nworld)  # each world starts the swing at its own angle
    d.qpos.assign(qpos.astype(np.float32))
    rc = mjw.create_render_context(mjm, nworld=nworld, cam_res=(W, H), render_rgb=True,
                                   render_depth=False, render_seg=False)
    rgb = wp.zeros((nworld, H, W), dtype=wp.vec3)

    def physics():
        for _ in range(NSUB):
            mjw.step(m, d)

    def draw():
        mjw.refit_bvh(m, d, rc)
        mjw.render(m, d, rc)
        mjw.get_rgb(rc, 0, rgb)

    mjw.forward(m, d)
    physics()                                       # warm-up: JIT-compile step kernels
    draw()                                          # warm-up: build the megakernel (rc._megakernel)
    if ON_GPU:
        with wp.ScopedCapture() as cap_phys:
            physics()
        with wp.ScopedCapture() as cap_draw:
            draw()
        run_phys = lambda: wp.capture_launch(cap_phys.graph)
        run_draw = lambda: wp.capture_launch(cap_draw.graph)
    else:
        run_phys, run_draw = physics, draw          # CPU: eager (no CUDA graphs)

    frames = []
    wp.synchronize()
    t0 = time.perf_counter()
    for _ in range(NFRAME):
        run_phys()
        run_draw()
        if keep_frames:                             # reading back costs a sync + copy
            frames.append((np.clip(rgb.numpy()[0], 0, 1) * 255).astype(np.uint8))
    wp.synchronize()
    dt = time.perf_counter() - t0
    return frames, dt, d


frames, _, d = rollout(NWORLDS[0], keep_frames=True)
print(f"world 0: {len(frames)} frames of {frames[0].shape} uint8, "
      f"the loop simulates {NFRAME * NSUB * mjm.opt.timestep:.3f} s")
print("swing angle per world after the rollout:", np.round(d.qpos.numpy()[:4, 0], 3))
print("mean brightness of frames 0, 4, last:",
      [round(float(frames[i].mean()), 1) for i in (0, 4, len(frames) - 1)])
print(f"{'nworld':>7} {'frames/s (all worlds)':>22} {'images/s':>10}   [{wp.get_device()}]")
for nw in NWORLDS:
    _, dt, _ = rollout(nw, keep_frames=False)
    print(f"{nw:7d} {NFRAME / dt:22.1f} {NFRAME * nw / dt:10.0f}")

if args.dump_png:
    os.makedirs(args.dump_png, exist_ok=True)
    strip = np.concatenate([np.pad(f, ((1, 1), (1, 1), (0, 0)), constant_values=255)
                            for f in frames], axis=1)
    save_png(os.path.join(args.dump_png, "ex11_filmstrip.png"), strip)
    print("wrote ex11_filmstrip.png", strip.shape, "to", args.dump_png)
if args.gif:
    try:
        from PIL import Image
        imgs = [Image.fromarray(f).resize((128, 128), Image.NEAREST) for f in frames]
        imgs[0].save(args.gif, save_all=True, append_images=imgs[1:], duration=66, loop=0)
        print("wrote", args.gif)
    except ImportError:
        print("skipped: Pillow not installed (no GIF)")
