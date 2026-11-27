"""Example 5.7 - chaos: float32 MJWarp and float64 C MuJoCo agree, then drift apart.

The double pendulum starts from the "horizontal" keyframe and runs NSTEP steps in both engines.
The two trajectories match to ~1e-7 at first; the double pendulum is chaotic, so that tiny
float32-vs-float64 difference grows exponentially until the motions are unrelated. A second
C MuJoCo run started 1e-9 rad away shows the same growth: it is the system, not a bug.
We switch the model to RK4, which keeps the pendulum's energy; with the default Euler
integrator the pendulum slowly loses energy, settles, and the divergence levels off (--euler).
Run: python ex7_chaos.py [--euler] [--dump-json PATH] [--plot PATH]
  --euler           keep the model's Euler integrator.
  --dump-json PATH  writes decimated |dq| curves and both pendulums' angles for the page chart
                    ("dt" there is the time between kept frames, "timestep" the physics step).
  --plot PATH       saves a log-scale plot (needs matplotlib).
"""
import argparse
import json

import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

np.set_printoptions(precision=4, suppress=True)

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
parser.add_argument("--euler", action="store_true")
parser.add_argument("--dump-json", default=None)
parser.add_argument("--plot", default=None)
args, _ = parser.parse_known_args()

NSTEP = 2000          # 20 s of simulated time; one world is enough for this comparison
DECIM = 10            # keep every 10th step for the page

mjm = mujoco.MjModel.from_xml_string(PENDULUM)
if not args.euler:
    mjm.opt.integrator = mujoco.mjtIntegrator.mjINT_RK4   # energy-preserving enough for 20 s
print("integrator:", mujoco.mjtIntegrator(mjm.opt.integrator).name)
key = mujoco.mj_name2id(mjm, mujoco.mjtObj.mjOBJ_KEY, "horizontal")

ref = mujoco.MjData(mjm)                      # C MuJoCo, float64
mujoco.mj_resetDataKeyframe(mjm, ref, key)
twin = mujoco.MjData(mjm)                     # C MuJoCo, float64, nudged by 1e-9 rad
mujoco.mj_resetDataKeyframe(mjm, twin, key)
twin.qpos[0] += 1e-9

m = mjw.put_model(mjm)
d = mjw.make_data(mjm, nworld=1)
mjw.reset_data_keyframe(m, d, key)            # MJWarp, float32

dq_warp = np.zeros(NSTEP)
dq_twin = np.zeros(NSTEP)
q_warp = np.zeros((NSTEP, 2))
q_ref = np.zeros((NSTEP, 2))
for i in range(NSTEP):
    mjw.step(m, d)
    mujoco.mj_step(mjm, ref)
    mujoco.mj_step(mjm, twin)
    q_warp[i] = d.qpos.numpy()[0]             # host read every step: fine for 1 world here
    q_ref[i] = ref.qpos
    dq_warp[i] = np.abs(q_warp[i] - q_ref[i]).max()
    dq_twin[i] = np.abs(twin.qpos - ref.qpos).max()

dt = mjm.opt.timestep
for thr in (1e-4, 1e-2, 1.0):
    first = lambda a: f"step {int(np.argmax(a > thr)) + 1}" if (a > thr).any() else "never"
    print(f"first |dq| > {thr:<6g}  MJWarp vs C: {first(dq_warp):<10} "
          f"C vs C+1e-9: {first(dq_twin)}")
print("max |dq| in the first 100 steps (MJWarp vs C):", f"{dq_warp[:100].max():.1e}")
print("q after 20 s  MJWarp:", q_warp[-1], " C:", q_ref[-1])

if args.dump_json:
    sl = slice(DECIM - 1, NSTEP, DECIM)
    lg = lambda a: [round(float(np.log10(max(x, 1e-12))), 3) for x in a]
    # "dt" is the time between kept frames (timestep x DECIM), as in the course replay format
    out = {"integrator": mujoco.mjtIntegrator(mjm.opt.integrator).name,
           "timestep": dt, "dt": dt * DECIM, "nstep": NSTEP, "decim": DECIM,
           "log10_dq_warp": lg(dq_warp[sl]), "log10_dq_twin": lg(dq_twin[sl]),
           "q_warp": np.round(q_warp[sl], 3).tolist(), "q_ref": np.round(q_ref[sl], 3).tolist()}
    with open(args.dump_json, "w") as f:
        json.dump(out, f, separators=(",", ":"))
    print("wrote", args.dump_json, len(out["q_warp"]), "frames")

if args.plot:
    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
    except ImportError:
        print("skipped: matplotlib not installed")
    else:
        t = np.arange(1, NSTEP + 1) * dt
        plt.semilogy(t, np.maximum(dq_warp, 1e-12), label="MJWarp (float32) vs C")
        plt.semilogy(t, np.maximum(dq_twin, 1e-12), label="C vs C + 1e-9 rad")
        plt.xlabel("time [s]"); plt.ylabel("max |dq| [rad]"); plt.legend()
        plt.savefig(args.plot, dpi=100)
        print("saved", args.plot)
