"""Example 26.4 - quadratic air drag through m.callback.passive.

passive.py::passive calls m.callback.passive(m, d) as its very last line, after it has summed
springs, dampers, gravity compensation, fluid and adhesion into d.qfrc_passive. A passive
callback must therefore ADD to qfrc_passive (+=), never overwrite it. Our kernel applies
F = -c |v| v to the ball's three linear DOFs (a free joint's qvel[0:3] is the world-frame linear
velocity), with a different drag coefficient c per world. The ball falls from 30 m and reaches
the terminal speed v_t = sqrt(m g / c).
Run: python ex4_passive_callback.py [--dump-json PATH]
  --dump-json PATH writes vz(t) of 4 worlds every 25 steps for the page's speed plot (Rule D).
"""
import argparse
import json

import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

np.set_printoptions(precision=4, suppress=True)

BALL_DROP = """
<mujoco model="ball_drop">
  <option timestep="0.002"/>
  <worldbody>
    <light pos="0 0 3" dir="0 0 -1"/>
    <geom name="floor" type="plane" size="5 5 .1" rgba=".8 .8 .8 1"/>
    <body name="ball" pos="0 0 1">
      <freejoint/>
      <geom name="ball" type="sphere" size=".1" mass="1" rgba="1 .3 .3 1"/>
    </body>
  </worldbody>
</mujoco>
"""

parser = argparse.ArgumentParser()
parser.add_argument("--dump-json", default=None)
args, _ = parser.parse_known_args()

ON_GPU = wp.get_device().is_cuda
NWORLD = 4096 if ON_GPU else 4
NSTEP = 1250                                 # 2.5 s: long enough to reach terminal speed


@wp.kernel
def quadratic_drag(
    # Data in:
    qvel_in: wp.array2d[float],
    # In:
    drag: wp.array[float],
    # Data out:
    qfrc_passive_out: wp.array2d[float],
):
    worldid = wp.tid()
    c = drag[worldid % drag.shape[0]]
    v = wp.vec3(qvel_in[worldid, 0], qvel_in[worldid, 1], qvel_in[worldid, 2])
    f = -c * wp.length(v) * v
    for i in range(3):
        qfrc_passive_out[worldid, i] += f[i]   # ADD: springs/dampers are already in here


drag = wp.array(np.geomspace(0.25, 2.0, NWORLD).astype(np.float32), dtype=float)
calls = [0]


def passive_callback(m, d):
    calls[0] += 1
    wp.launch(quadratic_drag, dim=d.nworld, inputs=[d.qvel, drag], outputs=[d.qfrc_passive])


mjm = mujoco.MjModel.from_xml_string(BALL_DROP)
m = mjw.put_model(mjm)
d = mjw.make_data(mjm, nworld=NWORLD, nconmax=4, njmax=16)
m.callback.passive = passive_callback

qpos = np.tile(mjm.qpos0, (NWORLD, 1)).astype(np.float32)
qpos[:, 2] = 30.0                            # high above the floor: no contact in 2.5 s
d.qpos.assign(qpos)
frames = []
for i in range(NSTEP):
    mjw.step(m, d)
    if args.dump_json and i % 25 == 24:      # host read for the figure only
        frames.append([round(float(v), 3) for v in d.qvel.numpy()[:4, 2]])
wp.synchronize()

vz = d.qvel.numpy()[:, 2]
c = drag.numpy()
vt = np.sqrt(1.0 * 9.81 / c)
print(f"callback calls: {calls[0]} for {NSTEP} steps (one per forward)")
print("drag c per world:     ", c[:4])
print("vz after 2.5 s [m/s]: ", vz[:4])
print("analytic -sqrt(mg/c): ", -vt[:4])
print("relative error:       ", np.abs(vz[:4] + vt[:4]) / vt[:4])
print("qfrc_passive[:, 2] = c vz^2 =", d.qfrc_passive.numpy()[:4, 2], "(balances m g = 9.81)")
print("height z [m]:         ", d.qpos.numpy()[:4, 2])

# without the callback the ball just free-falls: vz = -g t (2 s only: it would hit the floor)
m.callback.passive = None
d.qpos.assign(qpos)
d.qvel.zero_()
for _ in range(1000):
    mjw.step(m, d)
print("no callback, 2 s, vz:", d.qvel.numpy()[:4, 2], " (-g t =", round(-9.81 * 2.0, 3), ")")
print("overflow:", "none" if not d.overflow.numpy().any() else d.overflow.numpy())

if args.dump_json:
    with open(args.dump_json, "w") as f:
        json.dump({"nworld": 4, "dt": 25 * float(mjm.opt.timestep),
                   "drag": [round(float(x), 4) for x in c[:4]], "frames": frames},
                  f, separators=(",", ":"))
    print("wrote", args.dump_json, len(frames), "frames")
