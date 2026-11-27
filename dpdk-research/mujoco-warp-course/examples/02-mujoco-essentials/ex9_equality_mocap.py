"""Example 2.9 - a mocap target, a weld equality, and switching the weld off with eq_active.

MOCAP_TARGET: a mocap body "target" (moved by you, not by physics) and a free box welded to it.
For 2 s we move mocap_pos around a circle and the box follows; then eq_active[0] = 0 turns the
weld off and the box falls to the floor. The same schedule then runs in MJWarp, which uses the
same field names (d.mocap_pos, d.eq_active), and we compare the two trajectories.
Run: python ex9_equality_mocap.py [--dump-json PATH]
  --dump-json PATH  writes the MJWarp trajectory (target and box xyz) for the chapter replay
"""
import argparse
import json

import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

np.set_printoptions(precision=3, suppress=True)

MOCAP_TARGET = """
<mujoco model="mocap_target">
  <option timestep="0.002"/>
  <worldbody>
    <light pos="0 0 3" dir="0 0 -1"/>
    <geom name="floor" type="plane" size="5 5 .1"/>
    <body name="target" mocap="true" pos="0.2 0 0.5">
      <geom type="sphere" size=".03" contype="0" conaffinity="0" rgba="0 1 0 .5"/>
    </body>
    <body name="box" pos="0.2 0 0.5">
      <freejoint/>
      <geom type="box" size=".05 .05 .05" mass="0.5"/>
    </body>
  </worldbody>
  <equality><weld body1="box" body2="target" solref="0.02 1"/></equality>
</mujoco>
"""

parser = argparse.ArgumentParser()
parser.add_argument("--dump-json", default=None)
args, _ = parser.parse_known_args()

T_CIRCLE, T_FALL, R, Z = 2.0, 1.0, 0.2, 0.5


def target_at(t):
    """Target position at time t: a horizontal circle of radius R at height Z."""
    a = 2 * np.pi * t / T_CIRCLE
    return np.array([R * np.cos(a), R * np.sin(a), Z])


mjm = mujoco.MjModel.from_xml_string(MOCAP_TARGET)
mjd = mujoco.MjData(mjm)
box = mujoco.mj_name2id(mjm, mujoco.mjtObj.mjOBJ_BODY, "box")
print("nmocap =", mjm.nmocap, "| neq =", mjm.neq, "| eq_type:", mujoco.mjtEq(mjm.eq_type[0]).name,
      "| body_mocapid:", mjm.body_mocapid)
nstep = int((T_CIRCLE + T_FALL) / mjm.opt.timestep)
n_on = int(T_CIRCLE / mjm.opt.timestep)
c_box = np.zeros((nstep, 3))
for i in range(nstep):
    if i == n_on:
        mjd.eq_active[0] = 0          # weld off: the box is now a free body
        print(f"t={mjd.time:.2f}  eq_active[0] = 0")
    mjd.mocap_pos[0] = target_at(mjd.time)
    mujoco.mj_step(mjm, mjd)
    c_box[i] = mjd.xpos[box]
    if (i + 1) % 250 == 0:
        gap = np.linalg.norm(mjd.xpos[box] - mjd.mocap_pos[0])
        print(f"t={mjd.time:.2f}  target={mjd.mocap_pos[0]}  box={mjd.xpos[box]}  gap={gap:.3f}")

# The same loop in MJWarp: same field names, but arrays have a leading nworld axis.
m = mjw.put_model(mjm)
d = mjw.make_data(mjm, nworld=1, nconmax=8, njmax=64)
w_box, w_tgt = np.zeros((nstep, 3)), np.zeros((nstep, 3))
for i in range(nstep):
    if i == n_on:
        d.eq_active.assign(np.zeros((1, mjm.neq), dtype=bool))
    t = i * mjm.opt.timestep
    d.mocap_pos.assign(target_at(t).reshape(1, 1, 3).astype(np.float32))
    mjw.step(m, d)
    w_box[i] = d.xpos.numpy()[0, box]     # host read every step: fine for 1 world, slow at scale
    w_tgt[i] = target_at(t)
print("MJWarp d.mocap_pos shape:", d.mocap_pos.shape, "| d.eq_active shape:", d.eq_active.shape)
print(f"max |box_C - box_MJWarp| while welded: {np.abs(c_box[:n_on] - w_box[:n_on]).max():.2e} m")
print(f"box z at the end: C {c_box[-1, 2]:.4f}  MJWarp {w_box[-1, 2]:.4f} (half-size 0.05)")
print("overflow:", "none" if not d.overflow.numpy().any() else d.overflow.numpy())

if args.dump_json:
    k = 25   # every 25th step = 0.05 s -> 60 frames
    frames = [[[round(float(v), 3) for v in w_tgt[i]], [round(float(v), 3) for v in w_box[i]]]
              for i in range(0, nstep, k)]
    with open(args.dump_json, "w") as f:
        json.dump({"nworld": 1, "dt": k * float(mjm.opt.timestep), "kind": "mocap3d",
                   "labels": ["target", "box"], "weld_off_frame": n_on // k,
                   "frames": frames}, f, separators=(",", ":"))
    print("wrote", args.dump_json, len(frames), "frames")
