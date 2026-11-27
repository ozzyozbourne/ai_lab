"""Example 28.3 - a torch policy drives CARTPOLE: zero-copy obs out, actions copied in place.

Every step: torch reads qpos/qvel through zero-copy views, computes a linear feedback action
per world (gains scaled from 0 to 1 across the worlds), and the action tensor goes into d.ctrl
with wp.from_torch + wp.copy. d.ctrl is never replaced, so its address (and any view or CUDA
graph that holds it) stays valid. No training here: the gains come from an LQR design.
Run: python ex3_torch_ctrl.py [--dump-json PATH]
  --dump-json PATH writes decimated (cart x, pole angle) per world for the page's replay.
"""
import argparse
import json

import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

np.set_printoptions(precision=3, suppress=True)

try:
    import torch
except ImportError:
    torch = None
    print("skipped: torch not installed")

CARTPOLE = """
<mujoco model="cartpole">
  <option timestep="0.01" integrator="implicitfast"/>
  <worldbody>
    <light pos="0 -2 3" dir="0 1 -1"/>
    <camera name="front" pos="0 -4 1" xyaxes="1 0 0 0 0 1"/>
    <geom name="rail" type="capsule" fromto="-2 0 1 2 0 1" size=".02" contype="0" conaffinity="0"/>
    <body name="cart" pos="0 0 1">
      <joint name="slider" type="slide" axis="1 0 0" range="-1.8 1.8" limited="true" damping="0.1"/>
      <geom name="cart" type="box" size=".2 .1 .05" mass="1" contype="0" conaffinity="0"/>
      <body name="pole">
        <joint name="hinge" type="hinge" axis="0 1 0" damping="0.01"/>
        <geom name="pole" type="capsule" fromto="0 0 0 0 0 .6" size=".03" mass="0.1"
              contype="0" conaffinity="0"/>
      </body>
    </body>
  </worldbody>
  <actuator><motor name="push" joint="slider" gear="10" ctrlrange="-1 1" ctrllimited="true"/></actuator>
  <sensor>
    <jointpos joint="slider"/><jointpos joint="hinge"/>
    <jointvel joint="slider"/><jointvel joint="hinge"/>
  </sensor>
</mujoco>
"""

parser = argparse.ArgumentParser()
parser.add_argument("--dump-json", default=None)
args, _ = parser.parse_known_args()

ON_GPU = wp.get_device().is_cuda
NWORLD = 4096 if ON_GPU else 8
NSTEP = 1000 if ON_GPU else 300
THETA0 = 0.2  # initial pole tilt [rad]; 0 = upright

if torch is not None:
    dev = wp.device_to_torch(wp.get_device())  # put torch work on Warp's device
    mjm = mujoco.MjModel.from_xml_string(CARTPOLE)
    m = mjw.put_model(mjm)
    d = mjw.make_data(mjm, nworld=NWORLD)  # no contacts in this model

    d.qpos.assign(np.tile([0.0, THETA0], (NWORLD, 1)).astype(np.float32))
    ctrl_ptr = d.ctrl.ptr

    # zero-copy views, made once: they follow d.qpos / d.qvel forever (never replaced)
    q, v = wp.to_torch(d.qpos), wp.to_torch(d.qvel)
    K = torch.tensor([[0.9, 6.8, 1.1, 1.2]], device=dev)        # LQR gains (x, th, xd, thd)
    gain = torch.linspace(0.0, 1.0, NWORLD, device=dev)[:, None]  # world k: gain[k] * K

    frames = []
    for i in range(NSTEP):
        obs = torch.cat([q, v], dim=1)                     # (nworld, 4), reads Warp memory
        act = ((obs @ K.T) * gain).clamp(-1.0, 1.0)         # (nworld, 1) == d.ctrl.shape
        wp.copy(d.ctrl, wp.from_torch(act.contiguous()))   # copy INTO d.ctrl, same address
        mjw.step(m, d)
        if args.dump_json and i % 5 == 0:
            qp = d.qpos.numpy()
            frames.append([[round(float(a), 3) for a in row] for row in qp])
    wp.synchronize()

    theta = d.qpos.numpy()[:, 1]
    wrapped = (theta + np.pi) % (2 * np.pi) - np.pi  # a pole that fell may have spun around
    print("device:", wp.get_device(), "| nworld:", NWORLD, "| steps:", NSTEP)
    print("gain scale per world:", gain[:8, 0].cpu().numpy())
    print("final pole angle [rad]:", theta[:8])
    upright = np.abs(wrapped) < 0.05
    print(f"mean |wrapped pole angle| = {np.abs(wrapped).mean():.3f} rad; upright worlds: "
          f"{int(upright.sum())}/{NWORLD}")
    print("d.ctrl address unchanged:", d.ctrl.ptr == ctrl_ptr)

    if args.dump_json:
        with open(args.dump_json, "w") as f:
            json.dump({"nworld": NWORLD, "dt": 5 * float(mjm.opt.timestep), "kind": "cartpole",
                       "labels": [f"g={g:.2f}" for g in gain[:, 0].cpu().tolist()],
                       "frames": frames}, f, separators=(",", ":"))
        print("wrote", args.dump_json, len(frames), "frames")
