"""Example 27.14 - camera modes follow a falling body; the ordering rule for manual cameras.

Four cameras watch a box thrown sideways: 'fixed' (world body), 'track' (moves with the box,
keeps its world orientation), 'trackcom' (moves with the subtree centre of mass) and 'target'
(fixed position, mode targetbody: turns to face the box). smooth.py::camlight recomputes
d.cam_xpos / d.cam_xmat inside every forward/step. So a camera you set by hand must be written
AFTER step and BEFORE refit_bvh/render, every frame; a write before step is overwritten.
Run: python ex14_camera_modes.py [--dump-json PATH]
  --dump-json PATH  writes the box and camera poses (world 0) for the page's 3-D widget.
"""
import argparse
import json

import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

np.set_printoptions(precision=3, suppress=True)

CAM_MODES = """
<mujoco model="camera_modes">
  <option timestep="0.005"/>
  <worldbody>
    <light pos="0 0 4" dir="0 0 -1" directional="true"/>
    <camera name="fixed" pos="0 -4 1.5" xyaxes="1 0 0 0 .35 .94"/>
    <camera name="target" mode="targetbody" target="box" pos="-2 -2 1"/>
    <geom name="floor" type="plane" size="5 5 .1" rgba=".8 .8 .8 1"/>
    <body name="box" pos="-1 0 1.5"><freejoint/>
      <geom name="box" type="box" size=".15 .15 .15" mass="1" rgba=".9 .3 .2 1"/>
      <geom name="weight" type="sphere" pos=".3 0 0" size=".08" mass="2" rgba=".2 .2 .9 1"/>
      <camera name="track" mode="track" pos="0 -1.5 .5" xyaxes="1 0 0 0 .3 .95"/>
      <camera name="trackcom" mode="trackcom" pos="0 -1.5 .5" xyaxes="1 0 0 0 .3 .95"/>
    </body>
  </worldbody>
</mujoco>
"""

parser = argparse.ArgumentParser()
parser.add_argument("--dump-json", default=None)
args, _ = parser.parse_known_args()

NWORLD, W, H = 4, 24, 24
NFRAME, NSUB = 5, 20                               # 5 frames, 0.1 s apart
mjm = mujoco.MjModel.from_xml_string(CAM_MODES)
m = mjw.put_model(mjm)
d = mjw.make_data(mjm, nworld=NWORLD, nconmax=8, njmax=32)
cams = [mujoco.mj_id2name(mjm, mujoco.mjtObj.mjOBJ_CAMERA, i) for i in range(mjm.ncam)]
print("cameras:", cams, "| cam_mode:", mjm.cam_mode.tolist(), "(0 fixed, 1 track, "
      "2 trackcom, 3 targetbody)")
qvel = np.zeros((NWORLD, mjm.nv), dtype=np.float32)
qvel[:, 0] = np.linspace(1.0, 2.5, NWORLD)        # each world throws the box at its own speed
qvel[:, 4] = 4.0                                   # and spins it about y (COM != body origin)
d.qvel.assign(qvel)
mjw.forward(m, d)

track, trackcom, target = cams.index("track"), cams.index("trackcom"), cams.index("target")
frames = []
for f in range(NFRAME):
    for i in range(NSUB):
        mjw.step(m, d)
        if args.dump_json and i % 5 == 4:          # 4 snapshots per frame for the widget
            frames.append((d.xpos.numpy()[0, 1].copy(), d.cam_xpos.numpy()[0].copy(),
                           d.cam_xmat.numpy()[0].copy(), d.xmat.numpy()[0, 1].copy(),
                           d.subtree_com.numpy()[0, 1].copy()))
    xpos = d.cam_xpos.numpy()
    fwd = -d.cam_xmat.numpy()[:, target][:, :, 2]  # camera looks along -z of cam_xmat
    print(f"t={d.time.numpy()[0]:.2f}s track x per world {xpos[:, track, 0]} | trackcom x w0 "
          f"{xpos[0, trackcom, 0]:+.3f} | target fwd w0 {fwd[0]}")

# the ordering rule: write the 'fixed' camera by hand, then render
rc = mjw.create_render_context(mjm, nworld=NWORLD, cam_res=(W, H), render_rgb=True,
                               render_depth=False, render_seg=False, cam_active=["fixed"])
rgb = wp.zeros((NWORLD, H, W), dtype=wp.vec3)
fixed = cams.index("fixed")


def render_fixed():
    mjw.refit_bvh(m, d, rc)
    mjw.render(m, d, rc)
    mjw.get_rgb(rc, 0, rgb)
    return rgb.numpy().copy()


def write_top_view():
    pos, mat = d.cam_xpos.numpy(), d.cam_xmat.numpy()
    pos[:, fixed] = [0.0, 0.0, 5.0]                # straight above, looking down (-z)
    mat[:, fixed] = np.eye(3)                      # columns = camera x, y, z axes in world
    d.cam_xpos.assign(pos)
    d.cam_xmat.assign(mat)


write_top_view()                                   # WRONG place: before step ...
mjw.step(m, d)                                     # ... camlight (in forward) overwrites it
print("written before step -> after step cam_xpos[0, fixed] =", d.cam_xpos.numpy()[0, fixed])
default = render_fixed()                           # the MJCF view of this exact state
write_top_view()                                   # RIGHT place: after step, before render
right = render_fixed()
changed = np.any(np.abs(right - default) > 1e-3, axis=-1).reshape(NWORLD, -1).mean(1)
print("written after step  -> cam_xpos[0, fixed] =", d.cam_xpos.numpy()[0, fixed],
      "| fraction of pixels changed per world:", changed.round(2))

if args.dump_json:
    out = {"cams": cams, "modes": mjm.cam_mode.tolist(), "dt": 5 * float(mjm.opt.timestep),
           "frames": [{"box": [round(float(v), 3) for v in b],
                       "com": [round(float(v), 3) for v in c],
                       "rot": [round(float(v), 3) for v in bm.ravel()],
                       "pos": [[round(float(v), 3) for v in p] for p in cp],
                       "fwd": [[round(float(-v), 3) for v in R[:, 2]] for R in cm],
                       "up": [[round(float(v), 3) for v in R[:, 1]] for R in cm]}
                      for b, cp, cm, bm, c in frames]}
    with open(args.dump_json, "w") as f:
        json.dump(out, f, separators=(",", ":"))
    print("wrote", args.dump_json)
