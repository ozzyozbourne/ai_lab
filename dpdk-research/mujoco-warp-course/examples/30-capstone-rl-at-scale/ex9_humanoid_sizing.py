"""Example 30.9 - contact track, step 1: size the buffers and pick the solver by measuring.

The Ch 9 recipe: run the real task with GENEROUS budgets and a policy that visits the bad states
(random actions make the humanoid fall, so feet, knees, hands and torso all hit the floor), and
record three worst cases: contacts per world, constraint rows per world, and the broadphase
candidate count d.ncollision (a TOTAL over all worlds, checked against naconmax). Add a 25%
margin. Then a small solver sweep on the same rollout: Newton vs CG, pyramidal vs elliptic cone,
3 vs 10 iterations. cone and solver are compile-time choices (new kernels per variant);
iterations is a runtime value. CPU numbers are from Warp's CPU device ("on a CPU dev box"),
not GPU performance.
Run: python ex9_humanoid_sizing.py [--dump-json PATH]
"""
import argparse
import json
import math
import time

import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw
from etils import epath

parser = argparse.ArgumentParser()
parser.add_argument("--dump-json", default=None)
args, _ = parser.parse_known_args()

ON_GPU = wp.get_device().is_cuda
NWORLD = 1024 if ON_GPU else 4
NSTEP = 1000 if ON_GPU else 120          # 0.005 s per step: 5 s on GPU, 0.6 s on CPU
HUMANOID_PATH = epath.resource_path("mujoco_warp") / "test_data/humanoid/humanoid.xml"


def humanoid_model():
    """The shipped humanoid (nq 28, nv 27, nu 21) plus three torso sensors added with MjSpec."""
    spec = mujoco.MjSpec.from_file(str(HUMANOID_PATH))
    xbody, body = mujoco.mjtObj.mjOBJ_XBODY, mujoco.mjtObj.mjOBJ_BODY   # XBODY = body frame;
    for name, kind, obj in [("torso_pos", mujoco.mjtSensor.mjSENS_FRAMEPOS, xbody),  # BODY would
                            ("torso_up", mujoco.mjtSensor.mjSENS_FRAMEZAXIS, xbody),  # be the COM
                            ("com_vel", mujoco.mjtSensor.mjSENS_SUBTREELINVEL, body)]:
        spec.add_sensor(name=name, type=kind, objtype=obj, objname="torso")
    return spec.compile()


def rollout(mjm, naconmax, njmax, iterations, measure):
    """Random actions from qpos0 + noise in every world; returns stats (and steps/s if timed)."""
    m = mjw.put_model(mjm)
    m.opt.iterations = iterations                 # runtime value: no recompile
    m.opt.warn_overflow = 0                       # no device printf; the bits are still set
    d = mjw.make_data(mjm, nworld=NWORLD, naconmax=naconmax, njmax=njmax)
    rng = np.random.default_rng(0)                # same states and actions for every variant
    qpos = np.tile(mjm.qpos0, (NWORLD, 1))
    qpos[:, 7:] += rng.uniform(-0.05, 0.05, (NWORLD, mjm.nq - 7))
    d.qpos.assign(qpos.astype(np.float32))
    acts = rng.uniform(-1, 1, (NSTEP, NWORLD, mjm.nu)).astype(np.float32)
    ctrl = [wp.array(a) for a in acts]
    mjw.step(m, d)                                # warm-up: compile this variant
    max_con = np.zeros(NWORLD, dtype=int)
    max_efc = np.zeros(NWORLD, dtype=int)
    max_ncol = 0
    niter, iters_bit = [], 0
    wp.synchronize()
    t0 = time.perf_counter()
    for i in range(NSTEP):
        wp.copy(d.ctrl, ctrl[i])
        mjw.step(m, d)
        if measure:                               # host reads: measurement only, never in RL
            n = int(d.nacon.numpy()[0])
            wid = d.contact.worldid.numpy()[:min(n, d.naconmax)]
            max_con = np.maximum(max_con, np.bincount(wid, minlength=NWORLD))
            max_efc = np.maximum(max_efc, d.nefc.numpy())
            max_ncol = max(max_ncol, int(d.ncollision.numpy()[0]))
            niter.append(d.solver_niter.numpy().mean())
    wp.synchronize()
    sec = time.perf_counter() - t0
    ov = d.overflow.numpy()
    iters_bit = int(np.count_nonzero(ov & mjw.OverflowType.ITERATIONS))
    other = int(np.count_nonzero(ov & ~int(mjw.OverflowType.ITERATIONS)))
    bits = sorted({b.name for b in mjw.OverflowType if b != mjw.OverflowType.ITERATIONS
                   and (ov & b).any()})
    return dict(max_con=max_con, max_efc=max_efc, max_ncol=max_ncol,
                niter=float(np.mean(niter)) if niter else 0.0,
                iters_bit=iters_bit, other_overflow=other, bits=bits, sps=NSTEP * NWORLD / sec,
                z=d.qpos.numpy()[:, 2])


mjm = humanoid_model()
print("device:", wp.get_device(), "| nworld:", NWORLD, "| steps:", NSTEP,
      f"| nv {mjm.nv}, nu {mjm.nu}, ngeom {mjm.ngeom}")
# 1. measurement rollout with generous budgets (default solver: Newton, pyramidal, 10 iters)
big = rollout(mjm, naconmax=64 * NWORLD, njmax=512, iterations=10, measure=True)
assert big["other_overflow"] == 0, "the measurement budget itself overflowed: raise it"
con, efc, ncol = int(big["max_con"].max()), int(big["max_efc"].max()), big["max_ncol"]
NACONMAX = math.ceil(1.25 * max(ncol, int(big["max_con"].sum())))   # the pool holds BOTH
NJMAX = math.ceil(1.25 * efc)
print(f"torso height at the end: {np.round(big['z'], 2)} (standing starts at 1.28)")
print(f"max contacts per world: {big['max_con'].tolist()} -> worst {con}")
print(f"max constraint rows per world: {big['max_efc'].tolist()} -> worst {efc}")
print(f"max broadphase candidates (all worlds): {ncol} = {ncol / NWORLD:.1f} per world, "
      f"vs {con} contacts in the worst world")
print(f"recommended: naconmax={NACONMAX} ({NACONMAX / NWORLD:.1f} per world), njmax={NJMAX} "
      f"(worst case + 25%)")

# 2. solver sweep on the same rollout with the recommended sizes
rows = []
print(f"{'solver':7s} {'cone':10s} {'iters':>5s} {'mean niter':>10s} {'ITER bit':>8s} "
      f"{'max rows':>8s} {'steps/s':>9s}  other overflow")
for solver in (mujoco.mjtSolver.mjSOL_NEWTON, mujoco.mjtSolver.mjSOL_CG):
    for cone in (mujoco.mjtCone.mjCONE_PYRAMIDAL, mujoco.mjtCone.mjCONE_ELLIPTIC):
        for iters in (3, 10):
            mjm.opt.solver, mjm.opt.cone = solver, cone        # compile-time choices
            mes = rollout(mjm, NACONMAX, NJMAX, iters, measure=True)
            tim = rollout(mjm, NACONMAX, NJMAX, iters, measure=False)
            row = [solver.name[6:], cone.name[7:].lower(), iters, round(mes["niter"], 2),
                   mes["iters_bit"], int(mes["max_efc"].max()), round(tim["sps"]),
                   "|".join(mes["bits"]) or "none"]
            rows.append(row)
            print(f"{row[0]:7s} {row[1]:10s} {iters:5d} {row[3]:10.2f} {row[4]:5d}/{NWORLD} "
                  f"{row[5]:8d} {row[6]:9.0f}  {row[7]}")
print("ITER bit = worlds whose solver hit the iteration cap at least once (sticky until reset)")
if args.dump_json:
    with open(args.dump_json, "w") as f:
        json.dump({"source": "ex9_humanoid_sizing.py", "nworld": NWORLD, "nstep": NSTEP,
                   "max_con": big["max_con"].tolist(), "max_efc": big["max_efc"].tolist(),
                   "max_ncollision": ncol, "naconmax": NACONMAX, "njmax": NJMAX, "sweep": rows},
                  f, separators=(",", ":"))
    print("wrote", args.dump_json)
