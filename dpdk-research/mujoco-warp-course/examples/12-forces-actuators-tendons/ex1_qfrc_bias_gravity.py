"""Example 12.1 - qfrc_bias of a free ball is m*g, and the gravity trick behind it.

smooth.py::rne computes the bias force c(q, qdot) = gravity + Coriolis/centrifugal terms. It does
not add gravity as a force on every body. Instead _cacc_world sets the acceleration of the world
body to -gravity (the world "accelerates up" by g) and the forward pass carries that acceleration
to every body. A 0.5 kg ball at rest then needs qfrc_bias[z] = m g = 4.905 N to "stay put".
The second half checks MJWarp's qfrc_bias on the shipped humanoid against C MuJoCo, and dumps the
humanoid tree (branches, subtree ranges) that drives the RNE stepper on the page.
Run: python ex1_qfrc_bias_gravity.py [--dump-json PATH]
"""
import argparse
import json

import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw
from etils import epath

np.set_printoptions(precision=4, suppress=True)

parser = argparse.ArgumentParser()
parser.add_argument("--dump-json", default=None)
args, _ = parser.parse_known_args()

BALL = """
<mujoco model="ball">
  <option timestep="0.002"/>
  <worldbody>
    <body name="ball" pos="0 0 1">
      <freejoint/>
      <geom type="sphere" size=".1" mass="0.5"/>
    </body>
  </worldbody>
</mujoco>
"""

mjm = mujoco.MjModel.from_xml_string(BALL)
m = mjw.put_model(mjm)
d = mjw.make_data(mjm, nworld=2)
mjw.forward(m, d)
print("free ball, mass 0.5 kg, at rest")
print("  qfrc_bias (world 0):", d.qfrc_bias.numpy()[0])
print("  m * g =", 0.5 * 9.81)
print("  cacc of the world body (rot | lin):", d.cacc.numpy()[0, 0], "<- -gravity")
print("  cacc of the ball:                  ", d.cacc.numpy()[0, 1])

# spin the ball: a free body's bias force also holds the gyroscopic term w x (I w)
qvel = np.zeros((2, 6), dtype=np.float32)
qvel[1, 3:] = [0.0, 5.0, 5.0]                   # world 1 spins about (0, 1, 1)
d.qvel.assign(qvel)
mjw.forward(m, d)
print("world 1 spinning, qfrc_bias:", d.qfrc_bias.numpy()[1], "(sphere: I w is parallel to w)")

# humanoid: MJWarp vs C MuJoCo at a random pose and velocity
HUMANOID_PATH = epath.resource_path("mujoco_warp") / "test_data/humanoid/humanoid.xml"
hm = mujoco.MjModel.from_xml_path(str(HUMANOID_PATH))
hd = mujoco.MjData(hm)
rng = np.random.default_rng(0)
hd.qpos[7:] = rng.uniform(-0.3, 0.3, hm.nq - 7)
hd.qvel[:] = rng.uniform(-1.0, 1.0, hm.nv)
mujoco.mj_forward(hm, hd)
hmw = mjw.put_model(hm)
hdw = mjw.put_data(hm, hd, nworld=1)
mjw.forward(hmw, hdw)
err = np.abs(hdw.qfrc_bias.numpy()[0] - hd.qfrc_bias).max()
print(f"humanoid nv={hm.nv}, nbranch={hmw.nbranch}: max |qfrc_bias MJWarp - C| = {err:.2e}")

if args.dump_json:
    start = hmw.body_branch_start.numpy()
    flat = hmw.body_branches.numpy()
    out = {"names": [hm.body(i).name for i in range(hm.nbody)],
           "parent": hm.body_parentid.tolist(),
           "branches": [flat[start[b]:start[b + 1]].tolist() for b in range(hmw.nbranch)],
           "subtreenum": hmw.body_subtreenum.numpy().tolist(),
           "dofnum": hm.body_dofnum.tolist()}
    with open(args.dump_json, "w") as f:
        json.dump(out, f, separators=(",", ":"))
    print("wrote", args.dump_json)
