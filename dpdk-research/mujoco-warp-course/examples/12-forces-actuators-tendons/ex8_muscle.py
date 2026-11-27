"""Example 12.8 - a muscle's force-length curve, one world per length.

test_data/actuation/muscle.xml has a <muscle> on a spatial tendon between a sliding ball and a
world site. A muscle is dyntype MUSCLE + gaintype MUSCLE + biastype MUSCLE:
    force = gain(L, V) * act + bias(L)      (util_misc.muscle_gain, muscle_bias)
gain = -F0 * FL(L) * FV(V) is the active part, bias = -F0 * FP(L) the passive (stretch) part; both
are negative because a muscle pulls (it shortens its tendon). L is the length normalized so that
lengthrange maps onto gainprm range = (0.75, 1.05); F0 = gainprm[2], or scale / acc0 when it is
negative (the default -1). We hold act = 1 and qvel = 0 and sweep the length over 41 worlds.
Run: python ex8_muscle.py [--dump-json PATH] [--dump-png DIR]
"""
import argparse
import json
import os

import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw
from etils import epath

np.set_printoptions(precision=4, suppress=True)

parser = argparse.ArgumentParser()
parser.add_argument("--dump-json", default=None)
parser.add_argument("--dump-png", default=None)
args, _ = parser.parse_known_args()

PATH = epath.resource_path("mujoco_warp") / "test_data/actuation/muscle.xml"
mjm = mujoco.MjModel.from_xml_path(str(PATH))
prm = mjm.actuator_gainprm[0]
print("dyn/gain/bias:", mujoco.mjtDyn(mjm.actuator_dyntype[0]).name,
      mujoco.mjtGain(mjm.actuator_gaintype[0]).name, mujoco.mjtBias(mjm.actuator_biastype[0]).name)
print("gainprm (range0, range1, force, scale, lmin, lmax, vmax, fpmax, fvmax) =", prm[:9])
print("actuator_lengthrange =", mjm.actuator_lengthrange[0], "| actuator_acc0 =",
      round(float(mjm.actuator_acc0[0]), 4))

# tendon length = distance from the ball's site (at x = q) to the world site at x = 1
NW = 41
lengths = np.linspace(0.02, 0.98, NW)
m = mjw.put_model(mjm)
d = mjw.make_data(mjm, nworld=NW)
d.qpos.assign((1.0 - lengths)[:, None].astype(np.float32))
d.act.fill_(1.0)                       # fully activated muscle
mjw.forward(m, d)
# .copy(): on the CPU device .numpy() is a zero-copy view, so the next forward would overwrite F
L = d.actuator_length.numpy()[:, 0].copy()
F = d.actuator_force.numpy()[:, 0].copy()

# passive part alone: act = 0 leaves only the bias
d.act.zero_()
mjw.forward(m, d)
Fp = d.actuator_force.numpy()[:, 0].copy()

F0 = prm[2] if prm[2] > 0 else prm[3] / mjm.actuator_acc0[0]
print(f"peak force F0 = scale / acc0 = {F0:.4f}")
for i in (4, 12, 20, 28, 36):
    md = mujoco.MjData(mjm)
    md.qpos[0], md.act[0] = 1.0 - lengths[i], 1.0
    mujoco.mj_forward(mjm, md)
    print(f"  tendon length {L[i]:.3f}: force {F[i]:+.4f} (C {md.actuator_force[0]:+.4f}), "
          f"passive part {Fp[i]:+.4f}")
lr = mjm.actuator_lengthrange[0]
L0 = (lr[1] - lr[0]) / (prm[1] - prm[0])                     # length per normalized unit
print(f"active part (F - passive) peaks at length {L[np.argmin(F - Fp)]:.3f}; normalized length 1"
      f" is at {lr[0] + (1 - prm[0]) * L0:.3f}")

if args.dump_json:
    out = {"length": [round(float(x), 4) for x in L], "force": [round(float(x), 4) for x in F],
           "passive": [round(float(x), 4) for x in Fp], "F0": round(float(F0), 4),
           "prm": [round(float(x), 4) for x in prm[:9]],
           "lengthrange": [float(x) for x in mjm.actuator_lengthrange[0]]}
    with open(args.dump_json, "w") as f:
        json.dump(out, f, separators=(",", ":"))
    print("wrote", args.dump_json)

if args.dump_png:
    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
        fig, ax = plt.subplots(figsize=(5, 3))
        ax.plot(L, -F, label="total (act = 1)")
        ax.plot(L, -Fp, "--", label="passive (act = 0)")
        ax.set_xlabel("tendon length [m]")
        ax.set_ylabel("pull = -actuator_force [N]")
        ax.legend()
        fig.tight_layout()
        os.makedirs(args.dump_png, exist_ok=True)
        fig.savefig(os.path.join(args.dump_png, "ex8_muscle.png"), dpi=80)
        print("wrote", os.path.join(args.dump_png, "ex8_muscle.png"))
    except ImportError:
        print("skipped: matplotlib not installed")
