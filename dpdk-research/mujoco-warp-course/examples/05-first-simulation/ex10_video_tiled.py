"""Example 5.10 - a 3-second video of world 0 and a 3x3 tiled frame of 9 worlds.

Nine worlds start identical except for the ball's initial velocity (qvel[:, 0:3]). Every
1/FPS seconds the batch renderer draws all nine worlds in one call; we keep world 0's image as
a video frame and, at the end, tile the nine images into one 3x3 picture (world k goes to row
k // 3, column k % 3).
Run: python ex10_video_tiled.py [--dump-png DIR]
  --dump-png DIR  writes the 3x3 tile at t = 0.6 s and at t = 3 s for the page.
"""
import argparse
import os
import struct
import zlib

import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

PLAYGROUND = """
<mujoco model="playground">
  <option timestep="0.01"/>
  <worldbody>
    <light pos="0 0 3" dir="0 0 -1"/>
    <camera name="overview" pos="0.5 -3 1.5" xyaxes="1 0 0 0 0.45 0.9"/>
    <geom name="floor" type="plane" size="5 5 .1"/>
    <body name="ball" pos="0 0 1"><freejoint/>
      <geom type="sphere" size=".1" mass="1" rgba="1 .3 .3 1"/></body>
    <body name="box" pos="0.5 0 1"><freejoint/>
      <geom type="box" size=".1 .1 .1" rgba=".3 .3 1 1"/></body>
    <body name="arm" pos="0 1 1"><joint name="hinge" type="hinge" axis="0 1 0"/>
      <geom type="capsule" fromto="0 0 0 .5 0 0" size=".03"/></body>
  </worldbody>
  <actuator><motor joint="hinge" gear="1"/></actuator>
  <sensor><jointpos joint="hinge"/></sensor>
  <keyframe><key name="up" qpos="0 0 2 1 0 0 0  0.5 0 2 1 0 0 0  0.3"/></keyframe>
</mujoco>
"""


def save_png(path, img):
    """Write an (H, W, 3) uint8 array as an 8-bit RGB PNG (standard library only)."""
    h, w, _ = img.shape
    raw = b"".join(b"\x00" + img[y].tobytes() for y in range(h))   # filter type 0 per row

    def chunk(tag, data):
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data))

    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
                + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))


def tile(images, ncol):
    """(n, H, W, 3) -> (rows*H, ncol*W, 3); image k lands in row k // ncol, column k % ncol."""
    n, h, w, c = images.shape
    nrow = -(-n // ncol)
    pad = np.zeros((nrow * ncol - n, h, w, c), images.dtype)
    grid = np.concatenate([images, pad]).reshape(nrow, ncol, h, w, c)
    return grid.transpose(0, 2, 1, 3, 4).reshape(nrow * h, ncol * w, c)


parser = argparse.ArgumentParser()
parser.add_argument("--dump-png", default=None)
args, _ = parser.parse_known_args()

NWORLD, RES, FPS, SECONDS = 9, 64, 30, 3.0
mjm = mujoco.MjModel.from_xml_string(PLAYGROUND)
cam = mjm.camera("overview")                 # the same closer camera as Example 5.9
cam.pos[:] = (0.25, -1.6, 1.6)
cam.quat[:] = (np.cos(np.pi / 6), np.sin(np.pi / 6), 0.0, 0.0)
m = mjw.put_model(mjm)
d = mjw.make_data(mjm, nworld=NWORLD, nconmax=16, njmax=64)

qvel = np.zeros((NWORLD, mjm.nv), dtype=np.float32)
vx, vz = np.meshgrid([-0.3, 0.0, 0.3], [3.0, 1.5, 0.0])      # 3 x 3 combinations
qvel[:, 0], qvel[:, 2] = vx.ravel(), vz.ravel()               # ball free joint: dofs 0..2
d.qvel.assign(qvel)                                            # write in place

rc = mjw.create_render_context(mjm, nworld=NWORLD, cam_res=(RES, RES), render_rgb=True,
                               render_depth=False, render_seg=False)
rgb = wp.zeros((NWORLD, RES, RES), dtype=wp.vec3)


def render_all():
    mjw.refit_bvh(m, d, rc)
    mjw.render(m, d, rc)
    mjw.get_rgb(rc, 0, rgb)
    return (np.clip(rgb.numpy(), 0, 1) * 255).astype(np.uint8)    # (nworld, H, W, 3)


dt = float(m.opt.timestep.numpy()[0])
render_every = max(1, int(1.0 / (FPS * dt)))                   # same rule as mjwarp-record
nstep = round(SECONDS / dt)
mjw.forward(m, d)
frames, tiles = [render_all()[0]], {}
for i in range(1, nstep + 1):
    mjw.step(m, d)
    if i % render_every == 0:
        imgs = render_all()
        frames.append(imgs[0])
        if i in (60, nstep):
            tiles[i] = tile(imgs, 3)

video = np.stack(frames)
print(f"{nstep} steps, render every {render_every} steps -> {len(frames)} frames of world 0,"
      f" video array {video.shape}")
print("3x3 tile shape:", tiles[nstep].shape, "| ball x per world at the end:",
      d.qpos.numpy()[:, 0].round(2))
print("overflow:", "none" if not d.overflow.numpy().any() else d.overflow.numpy())

try:                                         # Rule O: optional video writers
    import mediapy as media
    media.write_video("world0.mp4", video, fps=1.0 / (render_every * dt))
    print("saved world0.mp4 with mediapy")
except Exception as e:                       # ImportError, or no ffmpeg
    try:
        from PIL import Image
        ims = [Image.fromarray(f) for f in video]
        ims[0].save("world0.gif", save_all=True, append_images=ims[1:],
                    duration=int(1000 * render_every * dt), loop=0)
        print(f"saved world0.gif with PIL (mediapy: {type(e).__name__})")
    except ImportError:
        print("skipped video file: neither mediapy nor PIL is installed")

if args.dump_png:
    os.makedirs(args.dump_png, exist_ok=True)
    for i, img in tiles.items():
        save_png(os.path.join(args.dump_png, f"ex10_tile_step{i}.png"), img)
    print("wrote", len(tiles), "tiles to", args.dump_png)
