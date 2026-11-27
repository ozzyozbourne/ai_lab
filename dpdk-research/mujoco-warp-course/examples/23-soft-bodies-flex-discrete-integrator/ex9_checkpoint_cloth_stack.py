"""Example 23.9 - Part V checkpoint "Cloth on a box stack under a throughput budget".

Model M11 cloth(6): a plane, box_stack(2) (model M4) and a 6x6 flexcomp cloth started 0.05
above the top box; no hfield and no SDF. Edge equality keeps the cloth inextensible, so both
IMPLICITFAST and DISCRETE are allowed (check_discrete only refuses flex elasticity under the
implicit integrators).
1. Size nconmax/njmax with the Ch 9 recipe: a rollout with generous buffers, the per-world
   peak contacts and rows, +25%, rounded up to the ladder. Then check: flex collision first
   writes candidates (before de-duplication) into a buffer that is also naconmax long, so a
   flex scene can set NARROWPHASE although nacon stayed below naconmax. Double what overflowed.
2. Sweep integrator x solver x cone with those sizes. For each config report the mean and max
   solver_niter, the overflow bits (ITERATIONS = some world hit the iteration cap), a
   stability check and world-steps/s. Pick the fastest config that converges in every world
   without overflow.
Run: python ex9_checkpoint_cloth_stack.py [--dump-json PATH]
CPU numbers are tiny and only rank the configs on this machine; on Colab the GPU prints yours.
"""
import argparse
import itertools
import json
import math
import time

import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

parser = argparse.ArgumentParser()
parser.add_argument("--dump-json", default=None)
args, _ = parser.parse_known_args()

ON_GPU = wp.get_device().is_cuda
NWORLD = 4096 if ON_GPU else 4
NSTEP = 1000 if ON_GPU else 150
LABEL = "(GPU numbers)" if ON_GPU else "(CPU dev box, not GPU numbers)"
ITERATIONS, TOLERANCE = 50, 1e-6
LADDER = [(2 + k % 2) * 2 ** (k // 2 + 3) for k in range(19)]   # io.py size ladder (Ch 9)


def box_stack_bodies(n=2, size=0.1):
    return "".join(f'<body name="box{i}" pos="0 0 {size + 2 * size * i + 0.001 * i:.4f}">'
                   f'<freejoint/><geom type="box" size="{size} {size} {size}"/></body>'
                   for i in range(n))


def cloth(n=6, z=0.45, integrator="implicitfast", solver="Newton", cone="pyramidal"):
    """Model M11: plane + box_stack(2) + an n x n cloth whose lowest point starts at z."""
    return f"""
<mujoco model="cloth_on_box_stack">
  <option timestep="0.005" integrator="{integrator}" solver="{solver}" cone="{cone}"
          iterations="{ITERATIONS}" tolerance="{TOLERANCE}"/>
  <worldbody>
    <light pos="0 0 3" dir="0 0 -1"/>
    <geom name="floor" type="plane" size="5 5 .1"/>
    {box_stack_bodies(2)}
    <flexcomp name="cloth" type="grid" count="{n} {n} 1" spacing=".06 .06 .06"
              pos="0 0 {z}" radius=".01" dim="2" mass=".1">
      <edge equality="true"/>
      <contact condim="3" selfcollide="none"/>
    </flexcomp>
  </worldbody>
</mujoco>
"""


def round_up_ladder(x):
    return next((v for v in LADDER if v >= x), int(x))


def describe_overflow(d):
    ov = d.overflow.numpy()
    if not ov.any():
        return "none"
    return ", ".join(f"{b.name} x{int(np.count_nonzero(ov & b))}" for b in mjw.OverflowType
                     if (ov & b).any())


def rollout(xml, nconmax, njmax, measure=False):
    mjm = mujoco.MjModel.from_xml_string(xml)
    m = mjw.put_model(mjm)
    m.opt.warn_overflow = 0
    d = mjw.make_data(mjm, nworld=NWORLD, nconmax=nconmax, njmax=njmax)
    mjw.step(m, d)                                   # compile outside the timed loop
    wp.synchronize()
    peak_con = np.zeros(NWORLD, int)
    peak_efc = np.zeros(NWORLD, int)
    niters = []
    nsamp = NSTEP // 10                              # timed runs: sample solver_niter every 10 steps
    niter_buf = wp.zeros(nsamp * NWORLD, dtype=int)  # on the device, copied out after the clock stops
    t0 = time.perf_counter()
    for i in range(NSTEP):
        mjw.step(m, d)
        if measure:                                  # sizing run: host reads every step (not timed)
            niters.append(d.solver_niter.numpy().copy())
            nacon = min(int(d.nacon.numpy()[0]), d.naconmax)
            w = d.contact.worldid.numpy()[:nacon]
            peak_con = np.maximum(peak_con, np.bincount(w, minlength=NWORLD))
            peak_efc = np.maximum(peak_efc, d.nefc.numpy())
        elif i % 10 == 9:                            # device-to-device copy, no host sync
            wp.copy(niter_buf, d.solver_niter, dest_offset=(i // 10) * NWORLD, count=NWORLD)
    wp.synchronize()
    sec = time.perf_counter() - t0
    niters = np.array(niters) if measure else niter_buf.numpy().reshape(nsamp, NWORLD)
    zbox = d.xpos.numpy()[:, 2, 2]                   # top box centre z, every world
    ok = bool(np.isfinite(d.qpos.numpy()).all()) and bool((np.abs(zbox - 0.301) < 0.02).all())
    bits = {b.name for b in mjw.OverflowType if (d.overflow.numpy() & b).any()}
    return dict(sec=sec, niter_mean=float(niters.mean()), niter_max=int(niters.max()),
                bits=bits, overflow=describe_overflow(d), stable=ok,
                peak_con=peak_con, peak_efc=peak_efc, mjm=mjm)


# ---- 1. size the buffers (Ch 9 recipe) ----
probe = rollout(cloth(), nconmax=256, njmax=512, measure=True)
mjm = probe["mjm"]
print(f"M11 cloth(6): nv {mjm.nv}  nflexvert {mjm.nflexvert}  nflexedge {mjm.nflexedge}  "
      f"ngeom {mjm.ngeom}")
print(f"sizing rollout ({NSTEP} steps, defaults 256/512): peak contacts per world "
      f"{probe['peak_con'].max()}, peak nefc {probe['peak_efc'].max()}")
NCONMAX = round_up_ladder(math.ceil(1.25 * probe["peak_con"].max()))
NJMAX = round_up_ladder(math.ceil(1.25 * probe["peak_efc"].max()))
print(f"recipe: nconmax={NCONMAX}, njmax={NJMAX} (peak x 1.25, ladder)")
FIX = {"NARROWPHASE": "nconmax", "BROADPHASE": "nconmax", "NEFC": "njmax"}
for attempt in range(4):
    r = rollout(cloth(), NCONMAX, NJMAX)
    bits = r["bits"] & set(FIX)
    print(f"check {attempt}: nconmax={NCONMAX} njmax={NJMAX} -> overflow {r['overflow']}")
    if not bits:
        break
    if "nconmax" in {FIX[b] for b in bits}:
        NCONMAX *= 2
    if "njmax" in {FIX[b] for b in bits}:
        NJMAX *= 2

# ---- 2. sweep the solver knobs ----
rows = []
print(f"{'integrator':12s} {'solver':6s} {'cone':9s} {'niter mean/max':>14s} "
      f"{'stable':>6s} {'world-steps/s':>13s}  overflow")
for integ, solver, cone in itertools.product(("implicitfast", "discrete"), ("Newton", "CG"),
                                             ("pyramidal", "elliptic")):
    r = rollout(cloth(integrator=integ, solver=solver, cone=cone), NCONMAX, NJMAX)
    r["wsps"] = NWORLD * NSTEP / r["sec"]
    rows.append(dict(integrator=integ, solver=solver, cone=cone,
                     niter_mean=round(r["niter_mean"], 2), niter_max=r["niter_max"],
                     stable=r["stable"],
                     overflow=r["overflow"], wsps=round(r["wsps"], 1)))
    print(f"{integ:12s} {solver:6s} {cone:9s} {r['niter_mean']:8.1f}/{r['niter_max']:<5d} "
          f"{str(r['stable']):>6s} {r['wsps']:13.0f}  {r['overflow']}")

good = [r for r in rows if r["stable"] and r["overflow"] == "none"]
best = max(good, key=lambda r: r["wsps"]) if good else None
if best:
    print(f"choice: integrator={best['integrator']} solver={best['solver']} cone={best['cone']} "
          f"nconmax={NCONMAX} njmax={NJMAX} -> {best['wsps']:.0f} world-steps/s "
          f"on {wp.get_device()} {LABEL}")
else:
    print("no config passed: raise iterations or the buffers and rerun")

if args.dump_json:
    with open(args.dump_json, "w") as f:
        json.dump({"device": str(wp.get_device()), "nworld": NWORLD, "nstep": NSTEP,
                   "nconmax": NCONMAX, "njmax": NJMAX, "rows": rows}, f, indent=0)
    print("wrote", args.dump_json)
