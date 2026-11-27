"""Example 13.9 - a convergence study in one launch: one timestep per world.

m.opt.timestep is a batched field: kernels read opt_timestep[worldid % opt_timestep.shape[0]].
Eight worlds get eight timesteps (0.1 ... 0.0005 s) and all of them step together. World k reaches
T = 1 s after T/dt_k steps; we read its qpos at exactly that step and compare it with a fine
float64 reference (C MuJoCo, RK4, dt = 1e-4). The slope of log(error) against log(dt) is the
order of the method: about 1 for Euler, about 4 for RK4 (until float32 round-off takes over).
Run: python ex9_dt_sweep.py [--dump-json PATH] [--dump-png DIR]
"""
import argparse
import json
import os

import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

PENDULUM = """
<mujoco model="double_pendulum">
  <option timestep="0.01"><flag energy="enable"/></option>
  <worldbody>
    <light pos="0 -2 3" dir="0 1 -1"/>
    <camera name="side" pos="0 -3 1" xyaxes="1 0 0 0 0 1"/>
    <body name="link1" pos="0 0 1.5">
      <joint name="hinge1" type="hinge" axis="0 1 0"/>
      <geom type="capsule" fromto="0 0 0 0 0 -.5" size=".04" mass="1"/>
      <body name="link2" pos="0 0 -.5">
        <joint name="hinge2" type="hinge" axis="0 1 0"/>
        <geom type="capsule" fromto="0 0 0 0 0 -.5" size=".04" mass="1"/>
        <site name="tip" pos="0 0 -.5"/>
      </body>
    </body>
  </worldbody>
  <actuator><motor name="shoulder" joint="hinge1" gear="1" ctrlrange="-5 5"/></actuator>
  <sensor>
    <jointpos name="q1" joint="hinge1"/>
    <jointvel name="v1" joint="hinge1"/>
    <framepos name="tip_pos" objtype="site" objname="tip"/>
  </sensor>
  <keyframe><key name="horizontal" qpos="1.5708 0"/></keyframe>
</mujoco>
"""

parser = argparse.ArgumentParser()
parser.add_argument("--dump-json", default=None)
parser.add_argument("--dump-png", default=None)
args, _ = parser.parse_known_args()

ON_GPU = wp.get_device().is_cuda
T_END = 1.0
DTS = np.array([0.1, 0.05, 0.025, 0.0125, 0.005, 0.0025, 0.001, 0.0005])   # one world per dt
NWORLD = len(DTS)
NSTEPS = np.rint(T_END / DTS).astype(int)                                 # 10 ... 2000
Q0 = [1.2, 0.0]
INTEGRATORS = {"Euler": mjw.IntegratorType.EULER, "RK4": mjw.IntegratorType.RK4,
               "implicit": mjw.IntegratorType.IMPLICIT,
               "implicitfast": mjw.IntegratorType.IMPLICITFAST}

mjm = mujoco.MjModel.from_xml_string(PENDULUM)

# float64 reference: C MuJoCo, RK4, tiny step
ref = mujoco.MjModel.from_xml_string(PENDULUM)
ref.opt.integrator, ref.opt.timestep = mujoco.mjtIntegrator.mjINT_RK4, 1e-4
rd = mujoco.MjData(ref)
rd.qpos[:] = Q0
for _ in range(int(round(T_END / 1e-4))):
    mujoco.mj_step(ref, rd)
q_ref = rd.qpos.copy()
print("reference qpos(T=1 s):", np.round(q_ref, 6))

errors = {}
for name, integ in INTEGRATORS.items():
    m = mjw.put_model(mjm)
    m.opt.integrator = integ
    m.opt.timestep = wp.array(DTS, dtype=float)       # per-world timestep, shape (nworld,)
    d = mjw.make_data(mjm, nworld=NWORLD)
    d.qpos.assign(np.tile(Q0, (NWORLD, 1)))
    q_at_T = np.zeros((NWORLD, mjm.nq))
    for i in range(1, NSTEPS.max() + 1):
        mjw.step(m, d)
        for w in np.flatnonzero(NSTEPS == i):          # world w just reached T
            q_at_T[w] = d.qpos.numpy()[w]
            assert abs(d.time.numpy()[w] - T_END) < 1e-4
    errors[name] = np.abs(q_at_T - q_ref).max(axis=1)


def order(err, dts, floor=2e-5):
    """Least-squares slope of log(err) vs log(dt), using points above the float32 floor."""
    keep = err > floor
    return float(np.polyfit(np.log(dts[keep]), np.log(err[keep]), 1)[0]), int(keep.sum())


print("dt [s]       " + "".join(f"{dt:>10.4f}" for dt in DTS))
for name, err in errors.items():
    print(f"{name:<13}" + "".join(f"{e:>10.1e}" for e in err))
print("estimated order (slope of log error vs log dt):")
for name, err in errors.items():
    p, n = order(err, DTS)
    print(f"  {name:<13}{p:5.2f}  (fit over {n} timesteps)")

if args.dump_json:
    with open(args.dump_json, "w") as f:
        json.dump({"dts": DTS.tolist(), "t_end": T_END,
                   "errors": {k: [float(f"{e:.3e}") for e in v] for k, v in errors.items()}}, f)
    print("wrote", args.dump_json)

if not args.dump_png:                                # write files only when asked
    print("plot not saved (pass --dump-png DIR to write ex9_dt_sweep.png)")
else:
    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
    except ImportError:
        print("skipped plot: matplotlib not installed")
    else:
        fig, ax = plt.subplots(figsize=(5, 4))
        for name, err in errors.items():
            ax.loglog(DTS, err, "o-", label=name)
        ax.loglog(DTS, 3 * DTS, "k:", label="slope 1")
        ax.loglog(DTS, 0.3 * DTS ** 4, "k--", label="slope 4")
        ax.set_xlabel("timestep dt [s]")
        ax.set_ylabel("max |qpos - reference| at t = 1 s")
        ax.legend()
        path = os.path.join(args.dump_png, "ex9_dt_sweep.png")
        fig.savefig(path, dpi=80, bbox_inches="tight")
        print("saved", path)
