"""Example 29.5 - a Jacobian by central finite differences, every perturbation its own world.

CARTPOLE starts hanging (hinge = pi) and gets a piecewise-constant force: KNOTS control values,
each held for HOLD steps. We want J = d(final cart x, final pole angle) / d(knot values), a
2 x KNOTS matrix. World 0 is the nominal; for each epsilon and each knot j, one world adds +eps
to knot j and one adds -eps. All of them run in ONE batched rollout (2 * KNOTS * len(EPS) + 1
worlds). The float64 C MuJoCo Jacobian is the reference, so we can see how the float32 error
depends on epsilon.
Run: python ex5_fd_jacobian.py [--dump-json PATH]
"""
import argparse
import json

import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

np.set_printoptions(precision=4, suppress=True)

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

KNOTS, HOLD = 5, 10                        # 5 control values x 10 steps = 0.5 s
U0 = np.array([0.3, -0.2, 0.4, 0.1, -0.3])  # nominal knot values (inside ctrlrange)
EPS = [1e-1, 3e-2, 1e-2, 3e-3, 1e-3, 3e-4, 1e-4, 3e-5, 1e-5]
NWORLD = 1 + 2 * KNOTS * len(EPS)          # 91: the same on CPU and GPU (tiny batch)


@wp.kernel
def set_knot(sched: wp.array2d[float], k: int, ctrl_out: wp.array2d[float]):
    w = wp.tid()
    ctrl_out[w, 0] = sched[w, k]


# one row of knot values per world: nominal, then (+eps_j, -eps_j) blocks per epsilon
sched = np.tile(U0, (NWORLD, 1))
for e, eps in enumerate(EPS):
    for j in range(KNOTS):
        sched[1 + 2 * (e * KNOTS + j), j] += eps
        sched[2 + 2 * (e * KNOTS + j), j] -= eps

mjm = mujoco.MjModel.from_xml_string(CARTPOLE)
m = mjw.put_model(mjm)
d = mjw.make_data(mjm, nworld=NWORLD)
q0 = mjm.qpos0.copy()
q0[1] = np.pi                              # pole hanging down
d.qpos.assign(np.tile(q0, (NWORLD, 1)))
sched_wp = wp.array(sched, dtype=float)
for k in range(KNOTS):                     # one batched rollout for all perturbations
    wp.launch(set_knot, dim=NWORLD, inputs=[sched_wp, k], outputs=[d.ctrl])
    for _ in range(HOLD):
        mjw.step(m, d)
out = d.qpos.numpy().astype(np.float64)    # (NWORLD, 2): final cart x, pole angle


def c_rollout(u):
    """float64 C MuJoCo, same schedule: the reference."""
    dd = mujoco.MjData(mjm)
    dd.qpos[:] = q0
    for k in range(KNOTS):
        dd.ctrl[0] = u[k]
        for _ in range(HOLD):
            mujoco.mj_step(mjm, dd)
    return dd.qpos.copy()


J_ref = np.zeros((2, KNOTS))
for j in range(KNOTS):
    up, um = U0.copy(), U0.copy()
    up[j] += 1e-6
    um[j] -= 1e-6
    J_ref[:, j] = (c_rollout(up) - c_rollout(um)) / 2e-6

print(f"nworld = {NWORLD} (1 nominal + 2 x {KNOTS} knots x {len(EPS)} epsilons), "
      f"{KNOTS * HOLD} steps")
print("nominal final [x, theta]: MJWarp", out[0], "| C MuJoCo", c_rollout(U0))
errs = []
for e, eps in enumerate(EPS):
    J = np.zeros((2, KNOTS))
    for j in range(KNOTS):
        r = 1 + 2 * (e * KNOTS + j)
        J[:, j] = (out[r] - out[r + 1]) / (2 * eps)
    err = float(np.abs(J - J_ref).max() / np.abs(J_ref).max())
    errs.append(err)
    print(f"eps = {eps:.0e}: max rel. error vs float64 = {err:.2e}")
    if eps == 1e-2:
        J_show = J
print("J (eps = 1e-2), rows = [x, theta], cols = knots:\n", J_show)
print("J reference (C MuJoCo, float64):\n", J_ref)
print("float32 machine epsilon:", np.finfo(np.float32).eps)

if args.dump_json:
    with open(args.dump_json, "w") as f:
        json.dump({"eps": EPS, "err": [round(v, 6) for v in errs],
                   "J": np.round(J_show, 4).tolist(), "J_ref": np.round(J_ref, 4).tolist()},
                  f, separators=(",", ":"))
    print("wrote", args.dump_json)
