"""Example 6.11 - many worlds at once: record on device, read once, then plot.

64 BALL_DROP worlds start at random heights; 256 PENDULUM worlds start at random q1.
A tiny kernel copies one column of the state into a (nstep, nworld) device buffer every
step, so the loop never syncs; one .numpy() at the end brings everything to the host.
Run: python ex10_batched_plots.py [--dump-json PATH] [--dump-png DIR]
  --dump-json PATH  writes PATH-stem_balls.json and _pendulums.json (decimated, for the page)
  --dump-png DIR    save the two matplotlib figures in DIR (default: no PNGs are written)
"""
import argparse
import json
import os

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


@wp.kernel
def record(src: wp.array2d(dtype=float), col: int, step: int, out: wp.array2d(dtype=float)):
    worldid = wp.tid()
    out[step, worldid] = src[worldid, col]      # row = step, column = world


def simulate(xml, nworld, nstep, init, cols, nconmax=None, njmax=None):
    """Run nworld worlds; return {name: (nstep, nworld) host array} for qpos/qvel columns."""
    mjm = mujoco.MjModel.from_xml_string(xml)
    m = mjw.put_model(mjm)
    d = mjw.make_data(mjm, nworld=nworld, nconmax=nconmax, njmax=njmax)
    qpos = np.tile(mjm.qpos0, (nworld, 1))
    init(qpos)
    d.qpos.assign(qpos)
    bufs = {name: wp.zeros((nstep, nworld), dtype=float) for name in cols}
    for i in range(nstep):
        mjw.step(m, d)
        for name, (field, col) in cols.items():
            wp.launch(record, dim=nworld, inputs=[getattr(d, field), col, i], outputs=[bufs[name]])
    out = {name: b.numpy() for name, b in bufs.items()}   # the only host reads
    out["overflow"] = d.overflow.numpy()
    return mjm, out


rng = np.random.default_rng(0)

# --- 64 bouncing balls ------------------------------------------------------------
NB, NSTEP_B = 64, 400
h0 = rng.uniform(0.4, 1.6, NB)


def init_ball(q):
    q[:, 2] = h0


mjm_b, ball = simulate(BALL_DROP, NB, NSTEP_B, init_ball, {"z": ("qpos", 2), "vz": ("qvel", 2)},
                       nconmax=4, njmax=16)
dt_b = mjm_b.opt.timestep
first_up = np.argmax(ball["vz"] > 0, axis=0)          # first step with upward velocity
t_bounce = (first_up + 1) * dt_b
t_pred = np.sqrt(2 * (h0 - 0.1) / 9.81)               # free fall to contact (radius 0.1)
print(f"balls: nworld={NB}, {NSTEP_B} steps of {dt_b} s, all bounced: {bool((first_up > 0).all())}")
print(f"  mean bounce time {t_bounce.mean():.4f} s, free-fall prediction {t_pred.mean():.4f} s")
print(f"  max |measured - predicted| {np.abs(t_bounce - t_pred).max():.4f} s")
print("  overflow:", "none" if not ball["overflow"].any() else ball["overflow"])

# --- 256 double pendulums -----------------------------------------------------------
NP, NSTEP_P = 256, 300
q10 = rng.uniform(-2.5, 2.5, NP)


def init_pend(q):
    q[:, 0] = q10


mjm_p, pend = simulate(PENDULUM, NP, NSTEP_P, init_pend, {"q1": ("qpos", 0), "v1": ("qvel", 0)})
flipped = (np.abs(pend["q1"]) > np.pi).any(axis=0)
print(f"pendulums: nworld={NP}, {NSTEP_P} steps of {mjm_p.opt.timestep} s")
print(f"  |v1| max over all worlds {np.abs(pend['v1']).max():.2f} rad/s,"
      f" worlds where link1 went over the top: {int(flipped.sum())}")

if args.dump_json:
    db, dp = 8, 6                                       # decimation (steps per frame)
    stem = os.path.splitext(args.dump_json)[0]          # data/ex10.json -> data/ex10_*.json
    balls = {"nworld": NB, "dt": db * dt_b, "kind": "height", "zmin": 0.0, "zmax": 1.7,
             "frames": np.round(ball["z"][::db].astype(np.float64), 3).tolist()}
    pends = {"nworld": NP, "dt": dp * mjm_p.opt.timestep, "kind": "phase",
             "q1": np.round(pend["q1"][::dp].astype(np.float64), 2).tolist(),
             "v1": np.round(pend["v1"][::dp].astype(np.float64), 2).tolist()}
    for suffix, payload in (("_balls.json", balls), ("_pendulums.json", pends)):
        with open(stem + suffix, "w") as f:
            json.dump(payload, f, separators=(",", ":"))
        print("wrote", stem + suffix)

if not args.dump_png:
    print("no plots saved (pass --dump-png DIR to write the two PNGs)")
else:
    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
    except ImportError:
        print("skipped plots: matplotlib not installed")
    else:
        t = np.arange(NSTEP_B) * dt_b
        fig, axes = plt.subplots(8, 8, figsize=(10, 8), sharex=True, sharey=True)
        for w, ax in enumerate(axes.flat):
            ax.plot(t, ball["z"][:, w], lw=1, color=f"C{w % 8}")
            ax.text(0.95, 0.9, f"w{w}", transform=ax.transAxes, ha="right", va="top", fontsize=7)
        fig.suptitle("ball z(t) [m] vs t [s], 64 worlds")
        fig.savefig(os.path.join(args.dump_png, "ex10_small_multiples.png"), dpi=80)
        fig, ax = plt.subplots(figsize=(6, 5))
        for w in range(NP):
            ax.plot(pend["q1"][:, w], pend["v1"][:, w], lw=0.4, alpha=0.5, color=f"C{w % 8}")
        ax.set_xlabel("q1 [rad]")
        ax.set_ylabel("v1 [rad/s]")
        ax.set_title("double pendulum phase portrait, 256 worlds")
        fig.savefig(os.path.join(args.dump_png, "ex10_phase_portrait.png"), dpi=80)
        print("saved ex10_small_multiples.png and ex10_phase_portrait.png in", args.dump_png)
